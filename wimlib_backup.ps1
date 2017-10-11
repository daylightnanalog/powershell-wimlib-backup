# ------------------------------------------------------------------------------
#    --------------------------   WIMLIB_BACKUP   --------------------------
# ------------------------------------------------------------------------------
# - requirements:
#       WMF 5.0+, Volume Shadow Copy (VSS) service enabled
# - this script backups $target in to a wim file at $backup_path
# - uses volume shadowcopy service to alow backup of opened files
# - uses deduplication of wim archive to greatly reduce size of the backup
# - settings are passed to the script as a config file, e.g mybackup_config.ini
# - wim file will be named based on the configs file name
#
# ----  values expected in config file  ----
# target=C:\test
# backup_path=C:\
# compression_level=LZX:20
# backup_wim_file_before_adding_new_image=false
# delete_old_backups=true
# keep_last_n=3
# keep_monthly=false
# keep_n_monthly=4
# keep_weekly=false
# keep_n_weekly=2
# ----------------------------------------------
# keep_last_n - integer, number of last backups that are kept no matter other settings
# keep_weekly - true/false, if set to true, keep one backup of every week
# keep_monthly - true/false, if set to true, keep one backup of every month


# ----------------------------------------------
# get path to the config file passed as a parameter, throw error if theres none
Param( [string]$config_path=$(throw "config file is mandatory, please provide as parameter") )

# absolute path to the wimlib executable
# rest of the paths used through out the script come either from config file
# or are relative paths to this scripts location
# --------------------------------------------------------------------
$wimlib_exe_full_path = "C:\ProgramData\wimlib_backup\wimlib-1.12.0-windows-x86_64-bin\wimlib-imagex.exe"
# --------------------------------------------------------------------

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$config_fullpath = Resolve-Path -Path $config_path
$config_file_name = (Get-Item $config_fullpath).name

#removes _config.ini from the name if its there, if its not, use the whole filename without the extention
if ($config_file_name.EndsWith('_config.ini')) {
    $pure_config_name = $config_file_name.Substring(0,($config_file_name.Length)-11)
} else {
    $pure_config_name = $config_file_name.Substring(0,($config_file_name.Length)-4)
}

# start logging in to log file that is named based on the config file
$log_file_name = $pure_config_name + ".log"
$log_file_full_path = Join-Path -Path $PSScriptRoot -ChildPath "logs" | Join-Path -ChildPath $log_file_name
Start-Transcript -Path $log_file_full_path -Append -Force
$OldVerbosePreference = $VerbosePreference
$VerbosePreference = 'Continue'

# read the content of the config file, ignore lines starting with #, rest load as variables
Get-Content $config_fullpath | Foreach-Object{
    if (-NOT $_.StartsWith("#")){
        $var = $_.Split('=')
        # load preset variables as booleans
        if (@('delete_old_backups','keep_monthly','keep_weekly', 'backup_wim_file_before_adding_new_image=false') -contains $var[0]) {
            New-Variable -Name $var[0] -Value ($var[1] -eq $true)
        # load what looks like numbers as integers
        } ElseIf ($var[1] -match "^\d+$") {
            $integer_version = [convert]::ToInt32($($var[1]), 10)
            New-Variable -Name $var[0] -Value $integer_version
        # rest as string
        } else {
            New-Variable -Name $var[0] -Value $var[1]
        }
    }
}

# some variables used through out the script
$script_start_date = Get-Date
$date = Get-Date -format "yyyy-MM-dd"
$unix_time = Get-Date -UFormat %s -Millisecond 0
$wim_image_name = $pure_config_name + "_" + $date + "_" + $unix_time

$t = Get-Date -format "yyyy-MM-dd || HH:mm:ss"
Write-Verbose " "
Write-Verbose "################################################################################"
Write-Verbose "#######                      $t                      #######"
Write-Verbose " "
Write-Verbose "-------------------------------------------------------------------------------"
Write-Verbose "- configuration file: $config_fullpath"
Write-Verbose "- log file: $log_file_full_path"
Write-Verbose " "
Write-Verbose "- user: $(whoami)"
Write-Verbose "- target: $target"
Write-Verbose "- backup to destination: $backup_path"
Write-Verbose "- compression_level: $compression_level"
Write-Verbose "- backup wim file before adding new image: $backup_wim_file_before_adding_new_image"
Write-Verbose " "
Write-Verbose "- delete_old_backups: $delete_old_backups"
Write-Verbose "- keep_last_n: $keep_last_n"
Write-Verbose "- keep_monthly: $keep_monthly"
Write-Verbose "- keep_weekly: $keep_weekly"
Write-Verbose "- keep_n_monthly: $keep_n_monthly"
Write-Verbose "- keep_n_weekly: $keep_n_weekly"

# running with admin privilages check
$running_as_admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-NOT $running_as_admin){
    throw "NOT RUNNING AS ADMIN, THE END"
}
# check if $target path exists on the system
if (-NOT (Test-Path $target)) {
    throw "NOT A VALID TARGET PATH: " + $target
}
# check if $backup_path path exists on the system
if (-NOT (Test-Path $backup_path)) {
    throw "NOT A VALID BACKUP PATH: " + $backup_path
}

# wim archive will be created/searched for on this path
$wim_file_full_path = Join-Path -Path $backup_path -ChildPath $($pure_config_name + ".wim")

#=================================================================
function verify_wim_image() {
    Param( [string]$path_to_wim_file, [string]$wimlib_exe)
    Write-Verbose "-------------------------------------------------------------------------------"
    Write-Verbose "WIM FILE INTEGRITY VERIFICATION"

    if (Test-Path $path_to_wim_file){
        Write-Verbose "- verification of: $path_to_wim_file"
        Try {
            & $wimlib_exe verify $path_to_wim_file
        } Catch {
            $old_name = (Get-Item $path_to_wim_file).Name
            $new_name = "corrupted_" + $old_name
            Write-Verbose "- verification failed"
            Write-Verbose "- renaming $old_name to $new_name"
            Rename-Item $path_to_wim_file $new_name
            #Remove-Item $path_to_wim_file -Force
        }
    } else {
        Write-Verbose "- no wim file at path: $path_to_wim_file"
    }
}
#=================================================================

verify_wim_image $wim_file_full_path $wimlib_exe_full_path


if (($backup_wim_file_before_adding_new_image -eq $True) -AND (Test-Path $wim_file_full_path)) {
    Write-Verbose "-------------------------------------------------------------------------------"
    Write-Verbose "COPY THE WIM FILE BEFORE ADDING NEW IMAGE"

    # backup the wim file before adding new image to guard for possible coccuption during adding of image
    $wim_file_backup_name = Join-Path -Path $backup_path -ChildPath $($pure_config_name + "_backup.wim")
    copy-item $wim_file_full_path $wim_file_backup_name -force
    Write-Verbose "- wim file copied: $wim_file_backup_name"
}


Write-Verbose "-------------------------------------------------------------------------------"
Write-Verbose "MAKE NEW BACKUP OF THE TARGET IN TO WIM ARCHIVE USING WIMLIB"

if (Test-Path $wim_file_full_path) {
    Write-Verbose "- adding new image in to the archive $wim_file_full_path"
    $command = 'append'
} else {
    Write-Verbose "- creating new wimlib archive $wim_file_full_path"
    $command = 'capture'
}

[Collections.ArrayList]$wimlib_arguments = $command, $target, $wim_file_full_path, $wim_image_name, "--snapshot", "--compress=$compression_level", "--check"

Write-Verbose "- this command will now be executed:"
Write-Verbose "$wimlib_exe_full_path $wimlib_arguments"

&$wimlib_exe_full_path $wimlib_arguments


Write-Verbose "-------------------------------------------------------------------------------"
Write-Verbose "DELETING OLD BACKUPS"

#=================================================================
# function to get date object from unix time
function Convert-UnixTime {
    Param( [Parameter(Mandatory=$true)][int32]$udate)

    $Timezone = (Get-TimeZone)
    if ($Timezone.SupportsDaylightSavingTime -eq $True){
        $TimeAdjust =  ($Timezone.BaseUtcOffset.TotalSeconds + 3600)
    } else {
        $TimeAdjust = ($Timezone.BaseUtcOffset.TotalSeconds)
    }

    # Adjust time from UTC to local based on offset that was determined before.
    $udate = ($udate + $TimeAdjust)

    # Retrieve start of UNIX Format
    $orig = (Get-Date -Year 1970 -Month 1 -Day 1 -hour 0 -Minute 0 -Second 0 -Millisecond 0)

    # Return final time
    return $orig.AddSeconds($udate)
}
#=================================================================

#=================================================================
# function to get human readable file size
function Get-FriendlySize {
    param($Bytes)
    $sizes='Bytes,KB,MB,GB,TB,PB,EB,ZB' -Split ','
    for($i=0; ($Bytes -ge 1kb) -and
        ($i -lt $sizes.Count); $i++) {$Bytes/=1kb}
    $N=2; if($i -eq 0) {$N=0}
    "{0:N$($N)} {1}" -f $Bytes, $sizes[$i]
}
#=================================================================

# always at least 1 backup
if ($keep_last_n -lt 1) {Set-Variable -Name "keep_last_n" -Value 1}

# get list of all images in the wim archive file
$all_previous_backups = @()

&$wimlib_exe_full_path info $wim_file_full_path | %{
    # get index of the image
    if ($_ -match "^Index:") {
        $wim_image_object = New-Object System.Object
        $var = $_.Split(':').Trim()
        $index_number = [convert]::ToInt32($($var[1]), 10)
        $wim_image_object | Add-Member -Type NoteProperty -Name "image_index" -Value $index_number
    }

    if ($_ -match "^Name:") {
        # get unix time from the images name (e.g. mybackup_2017-10-03_1507067975)
        $var = $_.Split('_').Trim()
        $epoch_time = [convert]::ToInt32($var[2], 10)
        $wim_image_object | Add-Member -Type NoteProperty -Name "creation_time" -Value $epoch_time

        # get date object from the unix time
        $date_object = Convert-UnixTime($epoch_time)
        $wim_image_object | Add-Member -Type NoteProperty -Name "creation_date_obj" -Value $date_object

        # get the year of the image
        $wim_image_object | Add-Member -Type NoteProperty -Name "year" -Value $date_object.Year

        # get month of the year
        $wim_image_object | Add-Member -Type NoteProperty -Name "month" -Value $date_object.Month

        # get week of the year
        $week_of_the_year = get-date $date_object -UFormat %V
        $wim_image_object | Add-Member -Type NoteProperty -Name "week" -Value $week_of_the_year

        $all_previous_backups += $wim_image_object
    }
}

# using array list instead of classic array to be able to remove from it easily
$sorted_by_creation_date = New-Object System.Collections.ArrayList
if ($all_previous_backups.Count -eq 1){
    $sorted_by_creation_date = $all_previous_backups
} else {
    $sorted_by_creation_date.AddRange($($all_previous_backups | Sort-Object -Descending creation_date_obj))
}

Write-Verbose "- delete old backups: $delete_old_backups"
Write-Verbose "- keeping last: $keep_last_n backups"
Write-Verbose "- keeping monthly backups: $keep_monthly"
Write-Verbose "- number of monthly backups kept: $keep_n_monthly"
Write-Verbose "- keeping weekly backups: $keep_weekly"
Write-Verbose "- number of weekly backups kept: $keep_n_weekly"
Write-Verbose " "
Write-Verbose "- wim file location: $wim_file_full_path"
$wim_file_size = Get-FriendlySize((Get-Item $wim_file_full_path).Length)
Write-Verbose "- wim file size: $wim_file_size"
Write-Verbose "- number of backups in the wim archive: $($sorted_by_creation_date.Count)"
Write-Verbose "- list current backups in the wim archive: "
Write-Output ($sorted_by_creation_date | Format-Table | Out-String)

if ($delete_old_backups -eq $true -AND $all_previous_backups.Count -gt $keep_last_n) {

    $backups_to_keep = @()

    # keeping the pre-set number of backups
    for ($i = 0; $i -lt $keep_last_n; $i++) {
        $backups_to_keep += $sorted_by_creation_date[$i]
    }

    # removing the latest $keep_last_n backups leaving only monthly and weekly to deal with
    $sorted_by_creation_date.RemoveRange(0, $keep_last_n)

    $keep_n_monthly_temp = $keep_n_monthly
    $keep_n_weekly_temp = $keep_n_weekly

    #=================================================================
    # function that gets list of images of a single year
    # returns the list of images to keep depending on month / week settings
    function month_week_cleanup_per_year(){
        Param( [array]$images_list, [boolean]$one_a_week, [boolean]$one_a_month )

        # hashtables are used to get only single file per month / week
        $keeping_this_images = @()
        $month_hashtable = @{}
        $week_hashtable = @{}

        # images_list sorted by newest first
        # this makes the final item in hastbale the very first occurance of that month / week
        foreach ($i in $images_list) {
            $month_hashtable[$i.month] = $i
            $week_hashtable[$i.week] = $i
        }

        # sort hashtables by month / week number, descending, the result are no hashtables
        $month_sorted = $month_hashtable.getenumerator() | Sort-Object @{e={$_.Name -as [int]}} -Descending
        $week_sorted = $week_hashtable.getenumerator() | Sort-Object @{e={$_.Name -as [int]}} -Descending


        if ($one_a_month -eq $true -AND $keep_n_monthly_temp -ge 1) {
            foreach ($i in $month_sorted) {
                $keeping_this_images += $i.Value
                $script:keep_n_monthly_temp--
                if ($keep_n_monthly_temp -lt 1) {break}
            }
        }

        if ($one_a_week -eq $true -AND $keep_n_weekly_temp -ge 1) {
            foreach ($i in $week_sorted) {
                $keeping_this_images += $i.Value
                $script:keep_n_weekly_temp--
                if ($keep_n_weekly_temp -lt 1) {break}
            }
        }

        return $keeping_this_images
    }
    #=================================================================

    # group by year and sort by date, so latest year go first
    $years_separated = $sorted_by_creation_date | Group-Object {$_.year}
    $years_separated = $years_separated | Sort-Object @{e={$_.Name -as [int]}} -Descending

    foreach ($i in $years_separated) {
        $backups_to_keep += month_week_cleanup_per_year $i.Group $keep_weekly $keep_monthly
    }

    Write-Verbose "- keeping these backups:"
    Write-Verbose ($backups_to_keep | Format-Table | Out-String)

    # actual deletion of unwanted backups
    foreach ($i in $sorted_by_creation_date) {
        if (-NOT ($backups_to_keep.creation_time -contains $i.creation_time)){
            [Collections.ArrayList]$wimlib_arguments = 'delete', $wim_file_full_path, $i.image_index
            Write-Verbose "- actual deletion of the backusp:"
            Write-Verbose "- this command will now be executed:"
            Write-Verbose "$wimlib_exe_full_path $wimlib_arguments"
            &$wimlib_exe_full_path $wimlib_arguments
        }
    }

} else {
    Write-Verbose "- deletion is disabled or fewer backups currently present than keep_last_n"
}


Write-Verbose "-------------------------------------------------------------------------------"
Write-Verbose "CREATING INFO FILE"

# creating nice and readable info file in the logs directory and next to the wim file
# it contains mostly the date information about the current backups
$current_backups = @()
&$wimlib_exe_full_path info $wim_file_full_path | %{

    # get index of the image
    if ($_ -match "^Index:") {
        $wim_image_object = New-Object System.Object
        $var = $_.Split(':').Trim()
        $aa = [convert]::ToInt32($($var[1]), 10)
        $wim_image_object | Add-Member -Type NoteProperty -Name "index" -Value $aa
    }

    if ($_ -match "^Name:") {
        # get unix time from the end of images name (example: mybackup_2017-10-03_1507067975)
        $var = $_.Split('_').Trim()
        $epoch_time = [convert]::ToInt32($var[2], 10)
        $date_object = Convert-UnixTime($epoch_time)

        # spacer, empty column so that the table looks better
        $wim_image_object | Add-Member -Type NoteProperty -Name " " -Value " "

        # get day of the week
        $week_day = Get-Date $date_object -format "dddd"
        $wim_image_object | Add-Member -Type NoteProperty -Name "weekday" -Value $week_day

        # get day, month in full name
        $day_month = Get-Date $date_object -format "dd-MMMM"
        $wim_image_object | Add-Member -Type NoteProperty -Name "day-month" -Value $day_month

        # spacer, empty column so that the table looks better
        $wim_image_object | Add-Member -Type NoteProperty -Name "  " -Value "  "

        # get week of the year
        $week_of_the_year = get-date $date_object -UFormat %V
        $wim_image_object | Add-Member -Type NoteProperty -Name "week" -Value $week_of_the_year

        # spacer, empty column so that the table looks better
        $wim_image_object | Add-Member -Type NoteProperty -Name "   " -Value "   "

        # full date
        $wim_image_object | Add-Member -Type NoteProperty -Name "full date" -Value $date_object

        $current_backups += $wim_image_object
    }
}

# create info file with the current state of the images
$logs_directory = (Get-Item $log_file_full_path).Directory
$info_file_path = Join-Path -path $logs_directory -ChildPath ($pure_config_name + ".txt")

$wim_file_size = Get-FriendlySize((Get-Item $wim_file_full_path).Length)

$wim_file_full_path | Out-File -FilePath $info_file_path -Encoding "UTF8"
$wim_file_size| Out-File -Append -FilePath $info_file_path -Encoding "UTF8"
(Get-Date).ToString() | Out-File -Append  -FilePath $info_file_path -Encoding "UTF8"


$wimlib_arguments = "info", $wim_file_full_path
$current_backups | Sort-Object -Descending 'full date' | Format-Table | Out-File -Append -FilePath $info_file_path -Encoding "UTF8"

Write-Verbose "- info file created: $info_file_path"

Copy-Item $info_file_path $backup_path
Write-Verbose "- info file copied next to wim file"

$runtime = (Get-Date) - $script_start_date
$readable_runtime = "{0:dd} days {0:hh} hours {0:mm} minutes {0:ss} seconds" -f $runtime

Write-Verbose "-------------------------------------------------------------------------------"
Write-Verbose " "
Write-Verbose "#######              $readable_runtime              #######"
Write-Verbose "################################################################################"
Write-Verbose " "

Stop-Transcript
$VerbosePreference = $OldVerbosePreference
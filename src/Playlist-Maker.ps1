<#
.SYNOPSIS
    Playlist Maker - Makes M3U playlists from your MP3s by decade, genre and artist, straight from their tags.

.DESCRIPTION
    PowerShell/WPF tool for making playlists from MP3 tags.

    It reads the ID3 tags of every MP3 in the music folders you add (artist, album artist,
    album, title, genre, year, track and length), then writes one .m3u8 (or .m3u) playlist per
    decade, genre, artist and decade-and-genre mix. It only ever writes playlists: the music
    files themselves are only read.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Playlist Maker v<version>\" release folders, their zips and
                                        "Playlist Maker.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Playlist Maker

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Playlist Maker v<version>".
$script:AppName     = 'Playlist Maker'
$script:AppVersion  = '1.00'
$script:Description = 'PowerShell/WPF tool for making playlists from MP3 tags'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Playlist-Maker'
$script:IsPrivate   = $false   # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.Playlist-Maker'   # taskbar ID; the shortcut made by New-PlaylistMakerShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Playlist Maker v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    # Source\src\<script> or Builds\<App> v<x.yy>\<script>: <project> is two levels up.
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')   # an unpacked release zip somewhere else
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
$script:CachePath    = Join-Path $script:DataDir 'tags.cache'     # tags read last time, so the next read is quick
$script:MadePath     = Join-Path $script:DataDir 'made.txt'       # the playlists this app has written
$script:KeptPath     = Join-Path $script:DataDir 'kept.txt'       # same-named playlists you chose to keep, made by something else
$script:ImportsPath  = Join-Path $script:DataDir 'imports.json'   # playlists you imported, as the songs they matched
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}

# Genre groups to start with: one per line, "Name = genre, genre, ...". Edit them with Edit groups...
$script:DefaultGroups = @(
    'Dance floor = Dance, Disco, House, Trance, Techno, Eurodance, Euro-House, Club, Club-House, Acid House, Progressive Trance, Drum & Bass, Rave'
    'Chill = Chillout, Chill-out, Ambient, New Age, Easy Listening, Trip-Hop, Downtempo, Lounge, Instrumental, Acoustic'
    'All Rock = Rock, Classic Rock, Hard Rock, Soft Rock, Progressive Rock, Gothic Rock, Southern Rock, Alternative Rock, Indie Rock, Glam Rock, Punk, Punk Rock, Metal, Heavy Metal, Rock & Roll, Rockabilly, Folk/Rock, Folk-Rock'
    'Soul & Funk = Soul, Northern Soul, R&B, Funk, Gospel, Motown, Jazz+Funk, Pop/Funk'
    'Jazz & Swing = Jazz, Big Band, Swing, Acid Jazz, Fusion, Bebop, Jive'
    'Ballads = Ballad, Power Ballad'
) -join "`n"

function Get-AppSetting {
    <# Settings from settings.json in the data folder, with the defaults for anything unset. #>
    $s = [ordered]@{
        Look = 'Light'; Folders = @()
        Decades = $true; Genres = $true; Artists = $true; Mixes = $true; Groups = $true; Shuffles = $true; MinSongs = 5
        GroupText = $script:DefaultGroups; SkipGenres = 'Spoken Word, Speech, Comedy, Trailer, Audiobook, Podcast'; ShuffleSizes = '10, 15, 25, 50, 100, 250'
        Order = 'Artist'; ArtistFrom = 'Artist'; Paths = 'Relative'; FileType = '.m3u8'
        SaveTo = 'One'; SubFolder = 'Playlists'; OneFolder = ''
    }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if (-not $s.Contains($p.Name)) { continue }
                $s[$p.Name] = switch ($p.Name) {
                    'Folders'  { @($p.Value | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
                    'MinSongs' { [int]$p.Value }
                    { $_ -in 'Decades', 'Genres', 'Artists', 'Mixes', 'Groups', 'Shuffles' } { [bool]$p.Value }
                    default    { [string]$p.Value }
                }
            }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#141A1B'; Card = '#1C2426'; Line = '#2F3B3E'; Ink = '#E6EEEE'; Soft = '#9AAAAD'; Accent = '#0F8F80'; AccentInk = '#FFFFFF'
       Field = '#121718'; Hover = '#243032'; Select = '#1E4A46'; Good = '#4CC38A'; Warn = '#E0A040'; Bad = '#F07178' }
} else {
    @{ Page = '#F3F7F7'; Card = '#FFFFFF'; Line = '#D6E0E0'; Ink = '#1C2728'; Soft = '#586668'; Accent = '#0F7A6E'; AccentInk = '#FFFFFF'
       Field = '#FFFFFF'; Hover = '#E9F3F2'; Select = '#D3ECE8'; Good = '#1E8A57'; Warn = '#9A5B00'; Bad = '#B3261E' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# A dark title bar in the dark look (Windows 10 20H1 and later; older Windows ignores it). #>
    if (-not $script:Dark) { return }
    try {
        if (-not ('PmDwm' -as [type])) { Add-Type -Namespace '' -Name 'PmDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = 1; [void][PmDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { Write-Verbose 'no dark title bar' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Add_SourceInitialized({ Set-TitleBar $this })
    return $w
}

# Shared styles: rounded buttons (normal and accent), slim scroll bars, text boxes, tick boxes,
# drop-down lists, list rows and the pill buttons that filter the list.
$script:Styles = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Card}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Select}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="BorderBrush" Value="{Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Opacity" Value="0.7"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="4" Background="{Line}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Width" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Height" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="8,0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,8,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal" Background="Transparent">
          <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" Background="{Field}" BorderBrush="{Line}" BorderThickness="1" VerticalAlignment="Center">
            <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="{AccentInk}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
          </Border>
          <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{Accent}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="Box" Property="Background" Value="{Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ComboToggle" TargetType="ToggleButton">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
        <Border x:Name="B" Background="{Field}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6">
          <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{Soft}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Height" Value="32"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Style="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
          <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,32,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6" Padding="4" Margin="0,4,0,0"
                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
              <ScrollViewer MaxHeight="360" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="B" Background="Transparent" Padding="10,7" CornerRadius="4"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Foreground" Value="{Ink}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="B" Background="Transparent" Padding="10,6" CornerRadius="6"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,0,6,6"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="15" Padding="13,5"><ContentPresenter VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Accent}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter Property="Foreground" Value="{AccentInk}"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,18,0,2"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Soft}"/><Setter Property="Margin" Value="0,10,0,0"/>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="480" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="20"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppMessage {
    <# A message, or a question (with -NoText: $true for the first button). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; $w.Close() })
    $no.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22" MaxWidth="440">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Playlist-Maker.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region TAGS
# ---------------------------------------------------------------------------
#  Reading the tags (C#, on background threads, so the window stays usable),
#  grouping the songs into playlists and writing them. Tags are read straight
#  from the files: ID3v2.2, 2.3 and 2.4 at the start, ID3v1 at the end. The
#  length comes from the first MPEG frame (Xing/Info/VBRI header for VBR files).
# ---------------------------------------------------------------------------
if (-not ('PmScan' -as [type])) {
    Add-Type -ReferencedAssemblies System.Xml -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

public static class PmText {
    public static string Clock(long s) {
        if (s <= 0) return "";
        return s >= 3600 ? string.Format("{0}:{1:00}:{2:00}", s / 3600, s / 60 % 60, s % 60) : string.Format("{0}:{1:00}", s / 60, s % 60);
    }
    public static string Long(long s) {
        if (s <= 0) return "length unknown";
        long m = (s + 30) / 60;
        if (m < 60) return m + " min";
        return (m / 60) + " h" + (m % 60 > 0 ? " " + (m % 60) + " min" : "");
    }
}

public class PmSong {
    public string Path { get; set; }
    public string Root { get; set; }
    public string Artist { get; set; }
    public string AlbumArtist { get; set; }
    public string Album { get; set; }
    public string Title { get; set; }
    public string Genre { get; set; }      // several genres are kept as "Rock;Pop"
    public int Year { get; set; }
    public int Track { get; set; }
    public int Disc { get; set; }
    public int Seconds { get; set; }
    public long Size { get; set; }
    public long Ticks { get; set; }
    internal string SortArtist = "";      // the artist as sorted, worked out once per build
    public PmSong() { Path = ""; Root = ""; Artist = ""; AlbumArtist = ""; Album = ""; Title = ""; Genre = ""; }
    public string ShownTitle { get { return Title.Length > 0 ? Title : System.IO.Path.GetFileNameWithoutExtension(Path); } }
    public string Line { get { return Artist.Length > 0 ? Artist + " - " + ShownTitle : ShownTitle; } }
    public string Info {
        get {
            var parts = new List<string>();
            if (Album.Length > 0) parts.Add(Album);
            parts.Add(Year > 0 ? Year.ToString() : "no year");
            parts.Add(Genre.Length > 0 ? Genre.Replace(";", ", ") : "no genre");
            if (Seconds > 0) parts.Add(PmText.Clock(Seconds));
            return string.Join("  \u00B7  ", parts.ToArray());
        }
    }
}

public static class PmTags {
    static readonly Encoding Latin1 = Encoding.GetEncoding(28591);
    // ID3v1 genre numbers (with the Winamp additions), used by "(17)" style ID3v2 genres too.
    static readonly string[] Genres = {
        "Blues","Classic Rock","Country","Dance","Disco","Funk","Grunge","Hip-Hop","Jazz","Metal","New Age","Oldies","Other","Pop","R&B","Rap",
        "Reggae","Rock","Techno","Industrial","Alternative","Ska","Death Metal","Pranks","Soundtrack","Euro-Techno","Ambient","Trip-Hop","Vocal",
        "Jazz+Funk","Fusion","Trance","Classical","Instrumental","Acid","House","Game","Sound Clip","Gospel","Noise","Alternative Rock","Bass",
        "Soul","Punk","Space","Meditative","Instrumental Pop","Instrumental Rock","Ethnic","Gothic","Darkwave","Techno-Industrial","Electronic",
        "Pop-Folk","Eurodance","Dream","Southern Rock","Comedy","Cult","Gangsta","Top 40","Christian Rap","Pop/Funk","Jungle","Native American",
        "Cabaret","New Wave","Psychedelic","Rave","Showtunes","Trailer","Lo-Fi","Tribal","Acid Punk","Acid Jazz","Polka","Retro","Musical",
        "Rock & Roll","Hard Rock","Folk","Folk-Rock","National Folk","Swing","Fast Fusion","Bebop","Latin","Revival","Celtic","Bluegrass",
        "Avantgarde","Gothic Rock","Progressive Rock","Psychedelic Rock","Symphonic Rock","Slow Rock","Big Band","Chorus","Easy Listening",
        "Acoustic","Humour","Speech","Chanson","Opera","Chamber Music","Sonata","Symphony","Booty Bass","Primus","Porn Groove","Satire",
        "Slow Jam","Club","Tango","Samba","Folklore","Ballad","Power Ballad","Rhythmic Soul","Freestyle","Duet","Punk Rock","Drum Solo",
        "A Cappella","Euro-House","Dance Hall","Goa","Drum & Bass","Club-House","Hardcore","Terror","Indie","BritPop","Negerpunk","Polsk Punk",
        "Beat","Christian Gangsta Rap","Heavy Metal","Black Metal","Crossover","Contemporary Christian","Christian Rock","Merengue","Salsa",
        "Thrash Metal","Anime","JPop","Synthpop","Abstract","Art Rock","Baroque","Bhangra","Big Beat","Breakbeat","Chillout","Downtempo","Dub",
        "EBM","Eclectic","Electro","Electroclash","Emo","Experimental","Garage","Global","IDM","Illbient","Industro-Goth","Jam Band","Krautrock",
        "Leftfield","Lounge","Math Rock","New Romantic","Nu-Breakz","Post-Punk","Post-Rock","Psytrance","Shoegaze","Space Rock","Trop Rock",
        "World Music","Neoclassical","Audiobook","Audio Theatre","Neue Deutsche Welle","Podcast","Indie Rock","G-Funk","Dubstep","Garage Rock","Psybient"
    };

    static int ReadFull(Stream s, byte[] b, int n) {
        int got = 0;
        while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) break; got += r; }
        return got;
    }
    static int Syncsafe(byte[] b, int o) { return (b[o] & 0x7F) << 21 | (b[o + 1] & 0x7F) << 14 | (b[o + 2] & 0x7F) << 7 | (b[o + 3] & 0x7F); }
    static int BE32(byte[] b, int o) { return b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]; }
    static byte[] Unsync(byte[] d) {
        var o = new List<byte>(d.Length);
        for (int i = 0; i < d.Length; i++) { o.Add(d[i]); if (d[i] == 0xFF && i + 1 < d.Length && d[i + 1] == 0) i++; }
        return o.ToArray();
    }
    static string Clean(string s) { return s.Replace("\uFEFF", "").Trim('\0', ' ', '\t', '\r', '\n'); }

    // A text frame's values (ID3v2.4 can hold several, separated by NULs).
    static List<string> Text(byte[] d, int off) {
        var vals = new List<string>();
        if (off >= d.Length) return vals;
        int enc = d[off];
        int n = d.Length - off - 1;
        string t;
        switch (enc) {
            case 1:
                if (n >= 2 && d[off + 1] == 0xFE && d[off + 2] == 0xFF) t = Encoding.BigEndianUnicode.GetString(d, off + 3, n - 2);
                else if (n >= 2 && d[off + 1] == 0xFF && d[off + 2] == 0xFE) t = Encoding.Unicode.GetString(d, off + 3, n - 2);
                else t = Encoding.Unicode.GetString(d, off + 1, n);
                t = t.Replace("\uFFFE", "");
                break;
            case 2: t = Encoding.BigEndianUnicode.GetString(d, off + 1, n); break;
            case 3: t = Encoding.UTF8.GetString(d, off + 1, n); break;
            default: t = Latin1.GetString(d, off + 1, n); break;
        }
        foreach (var p in t.Split('\0')) { var c = Clean(p); if (c.Length > 0) vals.Add(c); }
        return vals;
    }

    static string Map(string id) {
        switch (id) {
            case "TPE1": case "TP1": return "artist";
            case "TPE2": case "TP2": return "albumartist";
            case "TALB": case "TAL": return "album";
            case "TIT2": case "TT2": return "title";
            case "TCON": case "TCO": return "genre";
            case "TYER": case "TYE": case "TDRC": return "year";
            case "TORY": case "TOR": case "TDOR": return "orig";
            case "TRCK": case "TRK": return "track";
            case "TPOS": case "TPA": return "disc";
            case "TLEN": case "TLE": return "tlen";
        }
        return null;
    }

    public static int FirstNumber(string s, int digits) {
        var m = Regex.Match(s ?? "", digits == 4 ? @"\d{4}" : @"\d+");
        int v; return m.Success && int.TryParse(m.Value.Length > 6 ? m.Value.Substring(0, 6) : m.Value, out v) ? v : 0;
    }

    // "(17)", "(17)Rock", "17", "Rock" and "Rock;Pop" all become plain names.
    public static string Genre(IEnumerable<string> raw) {
        var outp = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Action<string> add = g => { g = g.Trim(); if (g.Length > 0 && seen.Add(g)) outp.Add(g); };
        foreach (var r0 in raw) {
            foreach (var part in r0.Split(';')) {
                string r = part.Trim();
                var refs = new List<string>();
                while (r.StartsWith("(") && !r.StartsWith("((")) {
                    int close = r.IndexOf(')');
                    if (close < 0) break;
                    string inner = r.Substring(1, close - 1);
                    int n;
                    if (int.TryParse(inner, out n)) { if (n >= 0 && n < Genres.Length) refs.Add(Genres[n]); }
                    else if (inner == "RX") refs.Add("Remix");
                    else if (inner == "CR") refs.Add("Cover");
                    r = r.Substring(close + 1).Trim();
                }
                if (r.StartsWith("((")) r = r.Substring(1);
                int num;
                if (r.Length > 0 && int.TryParse(r, out num)) { r = num >= 0 && num < Genres.Length ? Genres[num] : ""; }
                if (r.Length > 0) add(r); else foreach (var g in refs) add(g);
            }
        }
        return string.Join(";", outp.ToArray());
    }

    public static PmSong Read(string path) {
        var s = new PmSong { Path = path };
        var v = new Dictionary<string, List<string>>();
        long audioStart = 0;
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096)) {
            long len = fs.Length, audioEnd = len;
            byte[] h = new byte[10];
            if (ReadFull(fs, h, 10) == 10 && h[0] == 'I' && h[1] == 'D' && h[2] == '3' && h[3] >= 2 && h[3] <= 4) {
                int ver = h[3], flags = h[5], size = Syncsafe(h, 6);
                audioStart = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
                long end = Math.Min(len, 10 + (long)size);
                Stream st = fs;
                if ((flags & 0x80) != 0 && ver < 4) {
                    // The whole tag is "unsynchronised": undo it in memory first.
                    byte[] all = new byte[end - 10];
                    ReadFull(fs, all, all.Length);
                    all = Unsync(all);
                    st = new MemoryStream(all);
                    end = all.Length;
                }
                if ((flags & 0x40) != 0 && ver >= 3) {   // extended header
                    byte[] e = new byte[4];
                    ReadFull(st, e, 4);
                    int es = ver == 4 ? Syncsafe(e, 0) - 4 : BE32(e, 0);
                    if (es > 0) st.Seek(es, SeekOrigin.Current);
                }
                Frames(st, end, ver, v);
            }
            // ID3v1 at the end fills in anything the ID3v2 tag hasn't got.
            if (len >= 128) {
                byte[] t = new byte[128];
                fs.Seek(len - 128, SeekOrigin.Begin);
                if (ReadFull(fs, t, 128) == 128 && t[0] == 'T' && t[1] == 'A' && t[2] == 'G') {
                    audioEnd = len - 128;
                    Fill(v, "title", Clean(Latin1.GetString(t, 3, 30)));
                    Fill(v, "artist", Clean(Latin1.GetString(t, 33, 30)));
                    Fill(v, "album", Clean(Latin1.GetString(t, 63, 30)));
                    Fill(v, "year", Clean(Latin1.GetString(t, 93, 4)));
                    if (t[125] == 0 && t[126] != 0) Fill(v, "track", t[126].ToString());
                    if (t[127] < Genres.Length) Fill(v, "genre", Genres[t[127]]);
                }
            }
            s.Seconds = Length(fs, audioStart, audioEnd);
        }
        s.Artist = First(v, "artist");
        s.AlbumArtist = First(v, "albumartist");
        s.Album = First(v, "album");
        s.Title = First(v, "title");
        s.Genre = v.ContainsKey("genre") ? Genre(v["genre"]) : "";
        int orig = FirstNumber(First(v, "orig"), 4), year = FirstNumber(First(v, "year"), 4);
        s.Year = orig >= 1000 ? orig : year;      // the original year beats a reissue's year
        s.Track = FirstNumber(First(v, "track"), 0);
        s.Disc = FirstNumber(First(v, "disc"), 0);
        if (s.Seconds <= 0) { int ms = FirstNumber(First(v, "tlen"), 0); if (ms > 0) s.Seconds = (ms + 500) / 1000; }
        return s;
    }

    static string First(Dictionary<string, List<string>> v, string k) { List<string> l; return v.TryGetValue(k, out l) && l.Count > 0 ? l[0] : ""; }
    static void Fill(Dictionary<string, List<string>> v, string k, string val) {
        if (val.Length == 0 || (v.ContainsKey(k) && v[k].Count > 0)) return;
        v[k] = new List<string> { val };
    }

    static void Frames(Stream st, long end, int ver, Dictionary<string, List<string>> v) {
        int hdr = ver == 2 ? 6 : 10;
        byte[] fh = new byte[10];
        while (st.Position + hdr <= end) {
            if (ReadFull(st, fh, hdr) < hdr || fh[0] == 0) break;      // padding
            int idLen = ver == 2 ? 3 : 4;
            for (int i = 0; i < idLen; i++) { byte c = fh[i]; if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return; }
            string id = Encoding.ASCII.GetString(fh, 0, idLen);
            int size, fl = 0;
            if (ver == 2) size = fh[3] << 16 | fh[4] << 8 | fh[5];
            else {
                // Some programs wrote ID3v2.4 sizes the v2.3 way: a set top bit gives them away.
                bool plain = ver == 3 || ((fh[4] | fh[5] | fh[6] | fh[7]) & 0x80) != 0;
                size = plain ? BE32(fh, 4) : Syncsafe(fh, 4);
                fl = fh[8] << 8 | fh[9];
            }
            if (size <= 0 || st.Position + size > end) break;
            string key = Map(id);
            if (key == null || size > 1 << 20) { st.Seek(size, SeekOrigin.Current); continue; }
            byte[] d = new byte[size];
            if (ReadFull(st, d, size) < size) break;
            int off = 0;
            if (ver == 3) { if ((fl & 0x00C0) != 0) continue; if ((fl & 0x0020) != 0) off += 1; }
            if (ver == 4) {
                if ((fl & 0x000C) != 0) continue;            // compressed or encrypted
                if ((fl & 0x0002) != 0) d = Unsync(d);
                if ((fl & 0x0040) != 0) off += 1;            // group id
                if ((fl & 0x0001) != 0) off += 4;            // data length
            }
            var vals = Text(d, off);
            if (vals.Count == 0) continue;
            if (!v.ContainsKey(key) || key == "genre") {
                List<string> l;
                if (!v.TryGetValue(key, out l)) { l = new List<string>(); v[key] = l; }
                l.AddRange(vals);
            }
        }
    }

    static readonly int[] Br1 = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
    static readonly int[] Br2 = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };
    static readonly int[] Sr1 = { 44100, 48000, 32000 };

    // The song's length in seconds from the first MPEG audio frame.
    static int Length(FileStream fs, long start, long audioEnd) {
        if (start >= audioEnd) start = 0;
        byte[] b = new byte[65536];
        fs.Seek(start, SeekOrigin.Begin);
        int n = ReadFull(fs, b, b.Length);
        for (int i = 0; i + 4 < n; i++) {
            if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
            int ver = (b[i + 1] >> 3) & 3, layer = (b[i + 1] >> 1) & 3, bri = b[i + 2] >> 4, sri = (b[i + 2] >> 2) & 3, pad = (b[i + 2] >> 1) & 1;
            if (ver == 1 || layer != 1 || bri == 0 || bri == 15 || sri == 3) continue;    // Layer III only
            bool m1 = ver == 3;
            int br = (m1 ? Br1 : Br2)[bri], sr = Sr1[sri] / (m1 ? 1 : ver == 2 ? 2 : 4);
            int flen = (m1 ? 144000 : 72000) * br / sr + pad;
            if (i + flen + 1 < n && (b[i + flen] != 0xFF || (b[i + flen + 1] & 0xE0) != 0xE0)) continue;   // not followed by another frame
            bool mono = (b[i + 3] >> 6) == 3;
            int side = m1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
            int spf = m1 ? 1152 : 576;
            long frames = 0;
            int x = i + 4 + side;
            if (x + 12 < n && ((b[x] == 'X' && b[x + 1] == 'i' && b[x + 2] == 'n' && b[x + 3] == 'g') || (b[x] == 'I' && b[x + 1] == 'n' && b[x + 2] == 'f' && b[x + 3] == 'o'))) {
                if ((BE32(b, x + 4) & 1) != 0) frames = (uint)BE32(b, x + 8);
            } else {
                int vb = i + 36;
                if (vb + 18 < n && b[vb] == 'V' && b[vb + 1] == 'B' && b[vb + 2] == 'R' && b[vb + 3] == 'I') frames = (uint)BE32(b, vb + 14);
            }
            if (frames > 0) return (int)Math.Round(frames * (double)spf / sr);
            long bytes = audioEnd - (start + i);
            return bytes > 0 ? (int)Math.Round(bytes * 8.0 / (br * 1000.0)) : 0;
        }
        return 0;
    }
}

// Finds the MP3s and reads them, four at a time, using the cache for files that haven't changed.
public static class PmScan {
    public static volatile bool Busy, Cancel;
    public static volatile string Phase = "", Now = "", Failure;
    public static int Found, Done, FromCache, Failed;
    public static List<PmSong> Songs;
    public static List<string> Problems = new List<string>();

    public static void Start(string[] roots, string cachePath) {
        Busy = true; Cancel = false; Phase = "Finding"; Now = ""; Failure = null; Found = 0; Done = 0; FromCache = 0; Failed = 0;
        Songs = null; Problems = new List<string>();
        Task.Run(() => {
            try { Run(roots, cachePath); }
            catch (Exception e) { Failure = e.Message; }
            finally { Busy = false; }
        });
    }

    static void Note(string what) { lock (Problems) { if (Problems.Count < 200) Problems.Add(what); } }

    static void Walk(string dir, string root, List<string[]> files) {
        if (Cancel) return;
        Now = dir;
        try {
            foreach (var f in Directory.EnumerateFiles(dir, "*.mp3"))
                if (string.Equals(System.IO.Path.GetExtension(f), ".mp3", StringComparison.OrdinalIgnoreCase)) { files.Add(new[] { root, f }); Found++; }
        } catch (Exception e) { Note(dir + "  (" + e.Message + ")"); }
        string[] subs;
        try { subs = Directory.GetDirectories(dir); } catch (Exception) { return; }
        foreach (var d in subs) {
            try {
                var a = File.GetAttributes(d);
                if ((a & FileAttributes.ReparsePoint) != 0) continue;                                     // links and junctions
                if ((a & FileAttributes.Hidden) != 0 && (a & FileAttributes.System) != 0) continue;     // Recycle Bin and the like
            } catch (Exception) { continue; }
            Walk(d, root, files);
        }
    }

    static void Run(string[] roots, string cachePath) {
        var cache = Load(cachePath);
        var files = new List<string[]>();
        foreach (var r in roots) {
            if (!Directory.Exists(r)) { Note(r + "  (folder not found)"); continue; }
            Walk(r, r, files);
        }
        if (Cancel) return;
        Phase = "Reading";
        var result = new PmSong[files.Count];
        Parallel.For(0, files.Count, new ParallelOptions { MaxDegreeOfParallelism = 4 }, (i, state) => {
            if (Cancel) { state.Stop(); return; }
            string root = files[i][0], p = files[i][1];
            Now = p;
            try {
                var fi = new FileInfo(p);
                long size = fi.Length, ticks = fi.LastWriteTimeUtc.Ticks;
                PmSong c;
                if (cache.TryGetValue(p, out c) && c.Size == size && c.Ticks == ticks) { Interlocked.Increment(ref FromCache); }
                else { c = PmTags.Read(p); c.Size = size; c.Ticks = ticks; }
                c.Root = root;
                result[i] = c;
            } catch (Exception e) { Interlocked.Increment(ref Failed); Note(p + "  (" + e.Message + ")"); }
            Interlocked.Increment(ref Done);
        });
        if (Cancel) return;
        var list = new List<PmSong>();
        foreach (var s in result) if (s != null) list.Add(s);
        // Keep what's cached for folders that weren't read this time, so adding one back is quick.
        var keep = new List<PmSong>(list);
        var here = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in list) here.Add(s.Path);
        foreach (var kv in cache) {
            bool under = false;
            foreach (var r in roots) if (kv.Key.StartsWith(r.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) { under = true; break; }
            if (!under && !here.Contains(kv.Key)) keep.Add(kv.Value);
        }
        try { Save(cachePath, keep); } catch (Exception e) { Note("The tag cache couldn't be saved  (" + e.Message + ")"); }
        Songs = list;
    }

    static string F(string s) { return (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }

    static Dictionary<string, PmSong> Load(string path) {
        var d = new Dictionary<string, PmSong>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(path)) return d;
        try {
            using (var r = new StreamReader(path, Encoding.UTF8)) {
                if (r.ReadLine() != "PM1") return d;
                string line;
                while ((line = r.ReadLine()) != null) {
                    var f = line.Split('\t');
                    if (f.Length < 12) continue;
                    var s = new PmSong { Path = f[0], Size = long.Parse(f[1]), Ticks = long.Parse(f[2]), Artist = f[3], AlbumArtist = f[4], Album = f[5],
                                         Title = f[6], Genre = f[7], Year = int.Parse(f[8]), Track = int.Parse(f[9]), Disc = int.Parse(f[10]), Seconds = int.Parse(f[11]) };
                    d[s.Path] = s;
                }
            }
        } catch (Exception) { d.Clear(); }
        return d;
    }

    static void Save(string path, List<PmSong> songs) {
        string tmp = path + ".new";
        using (var w = new StreamWriter(tmp, false, new UTF8Encoding(false))) {
            w.WriteLine("PM1");
            foreach (var s in songs)
                w.WriteLine(string.Join("\t", new[] { F(s.Path), s.Size.ToString(), s.Ticks.ToString(), F(s.Artist), F(s.AlbumArtist), F(s.Album), F(s.Title),
                                                      F(s.Genre), s.Year.ToString(), s.Track.ToString(), s.Disc.ToString(), s.Seconds.ToString() }));
        }
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }
}

public class PmOptions {
    public bool Decades = true, Genres = true, Artists = true, Mixes = true, Groups = true, Shuffles = true, AlbumArtist = false, Each = true;
    public string GroupText = "", Skip = "", ShuffleSizes = "";
    public int Min = 5;
    public string Order = "Artist", Ext = ".m3u8", SubFolder = "Playlists", OneFolder = "";
    public string[] Roots = new string[0];
}

public class PmList {
    public string Kind { get; set; }      // Decade, Genre, Artist or Mix
    public string Name { get; set; }
    public string Folder { get; set; }
    public string File { get; set; }
    public string State { get; set; }     // New, Changed or Up to date
    public int Missing { get; set; }      // an imported playlist's songs that aren't in your music
    public List<PmSong> Songs { get; set; }
    public PmList() { Songs = new List<PmSong>(); State = ""; }
    public int Count { get { return Songs.Count; } }
    public long Seconds { get { long t = 0; foreach (var s in Songs) t += s.Seconds; return t; } }
    public string Info { get { return Count.ToString("N0") + (Count == 1 ? " song" : " songs") + "  \u00B7  " + PmText.Long(Seconds) + (Missing > 0 ? "  \u00B7  " + Missing.ToString("N0") + " not found" : ""); } }
    public string Where { get { return Kind + "  \u00B7  " + System.IO.Path.GetFileName(File) + "  \u00B7  in " + Folder; } }
}

// Groups the songs into playlists.
public static class PmBuild {
    static readonly Regex Feat = new Regex(@"\s*[\(\[]?\s*\b(feat\.?|ft\.|featuring)\s.*$", RegexOptions.IgnoreCase);
    static readonly Random Rng = new Random();

    public static string ArtistOf(PmSong s, bool albumArtist) {
        string a = albumArtist && s.AlbumArtist.Length > 0 ? s.AlbumArtist : s.Artist;
        return Feat.Replace(a, "").Trim();
    }
    static bool Various(string a) {
        a = a.ToLowerInvariant();
        return a == "various artists" || a == "various" || a == "va" || a == "[various artists]";
    }
    // Songs from before 1950 share one playlist, so do songs from 2010 on; one per decade in between.
    public const string Early = "Before 1950", Late = "2010 onwards";
    public static string DecadeOf(int y) {
        if (y < 1000 || y > DateTime.Now.Year + 1) return null;
        return y < 1950 ? Early : y >= 2010 ? Late : (y / 10 * 10) + "s";
    }
    static string SortKey(string k) { return k.StartsWith(Early) ? "0" + k : k; }   // "Before 1950" first

    public static List<string> SplitList(string text) {
        var l = new List<string>();
        foreach (var t in (text ?? "").Split(',', ';', '\n', '\r')) { var v = t.Trim(); if (v.Length > 0) l.Add(v); }
        return l;
    }

    // "Name = genre, genre" lines; a song is in a group when one of its genres is listed.
    public static List<KeyValuePair<string, HashSet<string>>> ParseGroups(string text) {
        var groups = new List<KeyValuePair<string, HashSet<string>>>();
        foreach (var line in (text ?? "").Split('\n')) {
            int eq = line.IndexOf('=');
            if (eq < 0) eq = line.IndexOf(':');
            if (eq <= 0) continue;
            string name = line.Substring(0, eq).Trim();
            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var g in line.Substring(eq + 1).Split(',', ';')) { var v = g.Trim(); if (v.Length > 0) set.Add(v); }
            if (name.Length > 0 && set.Count > 0) groups.Add(new KeyValuePair<string, HashSet<string>>(name, set));
        }
        return groups;
    }

    public static List<PmList> Make(List<PmSong> songs, PmOptions o) {
        var all = new List<PmList>();
        foreach (var s in songs) s.SortArtist = ArtistOf(s, o.AlbumArtist);
        // Songs with a genre to leave out are left out of every playlist made here.
        var skip = new HashSet<string>(SplitList(o.Skip), StringComparer.OrdinalIgnoreCase);
        var use = skip.Count == 0 ? songs : songs.FindAll(s => {
            foreach (var g in s.Genre.Split(';')) if (skip.Contains(g.Trim())) return false;
            return true;
        });
        var groups = o.Groups ? ParseGroups(o.GroupText) : new List<KeyValuePair<string, HashSet<string>>>();
        if (o.Each) {
            foreach (var r in o.Roots) {
                var mine = use.FindAll(s => string.Equals(s.Root, r, StringComparison.OrdinalIgnoreCase));
                Scope(mine, System.IO.Path.Combine(r, o.SubFolder), o, all, groups);
            }
        } else if (o.OneFolder.Length > 0) Scope(use, o.OneFolder, o, all, groups);
        return all;
    }

    static void Add(Dictionary<string, PmList> d, string kind, string name, PmSong s) {
        PmList l;
        if (!d.TryGetValue(name, out l)) { l = new PmList { Kind = kind, Name = name }; d[name] = l; }
        l.Songs.Add(s);
    }

    static void Scope(List<PmSong> songs, string folder, PmOptions o, List<PmList> all, List<KeyValuePair<string, HashSet<string>>> groups) {
        var cmp = StringComparer.OrdinalIgnoreCase;
        var grp = new Dictionary<string, PmList>(cmp);
        var dec = new Dictionary<string, PmList>(cmp); var gen = new Dictionary<string, PmList>(cmp);
        var art = new Dictionary<string, PmList>(cmp); var mix = new Dictionary<string, PmList>(cmp);
        foreach (var s in songs) {
            string d = DecadeOf(s.Year);
            string[] gs = s.Genre.Length > 0 ? s.Genre.Split(';') : new string[0];
            if (o.Decades && d != null) Add(dec, "Decade", d, s);
            if (o.Genres) foreach (var g in gs) Add(gen, "Genre", g, s);
            if (o.Artists) { string a = s.SortArtist; if (a.Length > 0 && !Various(a)) Add(art, "Artist", a, s); }
            if (o.Mixes && d != null) foreach (var g in gs) Add(mix, "Mix", d + " " + g, s);
            foreach (var kv in groups) {
                foreach (var g in gs) if (kv.Value.Contains(g.Trim())) { Add(grp, "Group", kv.Key, s); break; }
            }
        }
        var names = new HashSet<string>(cmp);
        foreach (var d in new[] { dec, gen, grp, art, mix }) {
            var keys = new List<string>(d.Keys);
            keys.Sort((x, y) => cmp.Compare(SortKey(x), SortKey(y)));
            foreach (var k in keys) {
                var l = d[k];
                if (l.Songs.Count < Math.Max(1, o.Min)) continue;
                Sort(l.Songs, o.Order);
                l.Folder = folder;
                string baseName = Safe(l.Kind + " - " + l.Name), name = baseName;
                for (int n = 2; !names.Add(name); n++) name = baseName + " (" + n + ")";
                l.File = System.IO.Path.Combine(folder, name + o.Ext);
                all.Add(l);
            }
        }
        // Shuffles: a fresh random pick of so many songs each time the list is worked out.
        if (o.Shuffles) {
            var sizes = new List<int>();
            foreach (var t in SplitList(o.ShuffleSizes)) { int n; if (int.TryParse(t, out n) && n > 0 && !sizes.Contains(n)) sizes.Add(n); }
            sizes.Sort();
            foreach (int n in sizes) {
                if (songs.Count < n) continue;
                var pick = new List<PmSong>(songs);
                Sort(pick, "Shuffle");
                pick.RemoveRange(n, pick.Count - n);
                var l = new PmList { Kind = "Shuffle", Name = n + " songs", Folder = folder, Songs = pick };
                string baseName = Safe("Shuffle - " + l.Name), name = baseName;
                for (int k = 2; !names.Add(name); k++) name = baseName + " (" + k + ")";
                l.File = System.IO.Path.Combine(folder, name + o.Ext);
                all.Add(l);
            }
        }
    }

    public static Dictionary<string, PmSong> PathIndex(List<PmSong> songs) {
        var d = new Dictionary<string, PmSong>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in songs) d[s.Path] = s;
        return d;
    }

    // An imported playlist, in its own order, saved beside the music folder most of its songs are in.
    public static void AddImported(List<PmList> plan, Dictionary<string, PmSong> byPath, PmOptions o, string name, string[] paths, int notFound) {
        var l = new PmList { Kind = "Imported", Name = name, Missing = notFound };
        var roots = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in paths) {
            PmSong s;
            if (byPath.TryGetValue(p, out s)) { l.Songs.Add(s); int n; roots.TryGetValue(s.Root, out n); roots[s.Root] = n + 1; }
            else l.Missing++;                       // gone since it was imported
        }
        string folder = null;
        if (o.Each) {
            int most = -1;
            foreach (var r in o.Roots) { int n; roots.TryGetValue(r, out n); if (n > most) { most = n; folder = System.IO.Path.Combine(r, o.SubFolder); } }
        } else if (o.OneFolder.Length > 0) folder = o.OneFolder;
        if (folder == null) return;
        l.Folder = folder;
        string baseName = Safe(name), file = System.IO.Path.Combine(folder, baseName + o.Ext);
        for (int n = 2; plan.Exists(x => string.Equals(x.File, file, StringComparison.OrdinalIgnoreCase)); n++)
            file = System.IO.Path.Combine(folder, baseName + " (" + n + ")" + o.Ext);
        l.File = file;
        plan.Add(l);
    }

    public static string Safe(string name) {
        var sb = new StringBuilder();
        foreach (char c in name) {
            if (c == '/' || c == '\\') sb.Append('-');
            else if (Array.IndexOf(System.IO.Path.GetInvalidFileNameChars(), c) >= 0) sb.Append('_');
            else sb.Append(c);
        }
        string s = sb.ToString().Trim().TrimEnd('.', ' ');
        return s.Length > 120 ? s.Substring(0, 120).TrimEnd() : s;
    }

    static int Cmp(string a, string b) { return string.Compare(a, b, StringComparison.CurrentCultureIgnoreCase); }

    static void Sort(List<PmSong> l, string order) {
        if (order == "Shuffle") {
            lock (Rng) for (int i = l.Count - 1; i > 0; i--) { int j = Rng.Next(i + 1); var t = l[i]; l[i] = l[j]; l[j] = t; }
            return;
        }
        Comparison<PmSong> byAlbum = (a, b) => {
            int c = Cmp(a.SortArtist, b.SortArtist); if (c != 0) return c;
            c = Cmp(a.Album, b.Album); if (c != 0) return c;
            c = a.Disc.CompareTo(b.Disc); if (c != 0) return c;
            c = a.Track.CompareTo(b.Track); if (c != 0) return c;
            return Cmp(a.ShownTitle, b.ShownTitle);
        };
        if (order == "Year") l.Sort((a, b) => { int c = (a.Year == 0 ? 9999 : a.Year).CompareTo(b.Year == 0 ? 9999 : b.Year); return c != 0 ? c : byAlbum(a, b); });
        else if (order == "Title") l.Sort((a, b) => { int c = Cmp(a.ShownTitle, b.ShownTitle); return c != 0 ? c : byAlbum(a, b); });
        else l.Sort(byAlbum);
    }
}

// Reads other playlists (.m3u, .m3u8, .pls, .wpl, .zpl, .xspf) and finds their songs in your music.
public class PmEntry { public string Path = ""; public string Hint = ""; }

public static class PmImport {
    static string Text(string file) {
        byte[] b = File.ReadAllBytes(file);
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return Encoding.UTF8.GetString(b, 3, b.Length - 3);
        if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return Encoding.Unicode.GetString(b, 2, b.Length - 2);
        if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(b, 2, b.Length - 2);
        try { return new UTF8Encoding(false, true).GetString(b); }        // UTF-8 without a BOM
        catch (Exception) { return Encoding.Default.GetString(b); }       // an older ANSI .m3u
    }

    static string Resolve(string dir, string p) {
        p = (p ?? "").Trim();
        if (p.Length == 0) return "";
        if (p.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) { try { p = new Uri(p).LocalPath; } catch (Exception) { return p; } }
        else if (Regex.IsMatch(p, @"^[A-Za-z][A-Za-z0-9+.\-]+://")) return p;     // a web stream: never in your music
        p = p.Replace('/', '\\');
        try { if (!(p.Length > 1 && p[1] == ':') && !p.StartsWith("\\\\")) p = System.IO.Path.GetFullPath(System.IO.Path.Combine(dir, p.TrimStart('\\'))); }
        catch (Exception) { }
        return p;
    }

    public static List<PmEntry> Parse(string file) {
        var list = new List<PmEntry>();
        string dir = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(file));
        string ext = System.IO.Path.GetExtension(file).ToLowerInvariant();
        string text = Text(file);
        if (ext == ".pls") {
            var paths = new SortedDictionary<int, string>(); var titles = new Dictionary<int, string>();
            foreach (var raw in text.Split('\n')) {
                var m = Regex.Match(raw.Trim(), @"^(File|Title)(\d+)=(.*)$", RegexOptions.IgnoreCase);
                if (!m.Success) continue;
                int n = int.Parse(m.Groups[2].Value);
                if (m.Groups[1].Value.ToLowerInvariant() == "file") paths[n] = m.Groups[3].Value; else titles[n] = m.Groups[3].Value.Trim();
            }
            foreach (var kv in paths) { string t; titles.TryGetValue(kv.Key, out t); list.Add(new PmEntry { Path = Resolve(dir, kv.Value), Hint = t ?? "" }); }
        } else if (ext == ".wpl" || ext == ".zpl" || ext == ".xspf") {
            var doc = new System.Xml.XmlDocument();
            doc.XmlResolver = null;
            doc.LoadXml(text);
            if (ext == ".xspf") {
                foreach (System.Xml.XmlNode t in doc.GetElementsByTagName("track")) {
                    string loc = "", creator = "", title = "";
                    foreach (System.Xml.XmlNode c in t.ChildNodes) {
                        if (c.LocalName == "location" && loc.Length == 0) loc = c.InnerText;
                        else if (c.LocalName == "creator") creator = c.InnerText.Trim();
                        else if (c.LocalName == "title") title = c.InnerText.Trim();
                    }
                    list.Add(new PmEntry { Path = Resolve(dir, loc), Hint = creator.Length > 0 && title.Length > 0 ? creator + " - " + title : title });
                }
            } else {
                foreach (System.Xml.XmlNode m in doc.GetElementsByTagName("media")) {
                    var a = m.Attributes["src"];
                    if (a != null) list.Add(new PmEntry { Path = Resolve(dir, a.Value) });
                }
            }
        } else {
            string hint = "";
            foreach (var raw in text.Split('\n')) {
                string l = raw.Trim();
                if (l.Length == 0) continue;
                if (l.StartsWith("#")) {
                    if (l.StartsWith("#EXTINF", StringComparison.OrdinalIgnoreCase)) { int c = l.IndexOf(','); hint = c >= 0 ? l.Substring(c + 1).Trim() : ""; }
                    continue;
                }
                list.Add(new PmEntry { Path = Resolve(dir, l), Hint = hint });
                hint = "";
            }
        }
        return list;
    }

    static string Norm(string s) {
        var sb = new StringBuilder();
        foreach (char c in (s ?? "").ToLowerInvariant()) if (char.IsLetterOrDigit(c)) sb.Append(c);
        return sb.ToString();
    }

    // Each entry's song: the same file; else the same file name in the same folders (a playlist made on another
    // PC, drive or NAS); else the same artist and title. What can't be found goes in notFound.
    public static List<PmSong> Match(List<PmEntry> entries, List<PmSong> songs, List<string> notFound) {
        var byPath = PmBuild.PathIndex(songs);
        var byName = new Dictionary<string, List<PmSong>>(StringComparer.OrdinalIgnoreCase);
        var byTag = new Dictionary<string, PmSong>();
        foreach (var s in songs) {
            string n = System.IO.Path.GetFileName(s.Path);
            List<PmSong> l;
            if (!byName.TryGetValue(n, out l)) { l = new List<PmSong>(); byName[n] = l; }
            l.Add(s);
            string k = Norm(s.Artist) + "|" + Norm(s.ShownTitle);
            if (!byTag.ContainsKey(k)) byTag[k] = s;
        }
        var found = new List<PmSong>();
        foreach (var e in entries) {
            PmSong hit = null;
            if (e.Path.Length > 0 && !byPath.TryGetValue(e.Path, out hit)) {
                var segs = e.Path.Split('\\');
                List<PmSong> cands;
                if (byName.TryGetValue(segs[segs.Length - 1], out cands)) {
                    int best = -1;
                    foreach (var s in cands) {
                        var ss = s.Path.Split('\\');
                        int k = 0;
                        while (k < ss.Length && k < segs.Length && string.Equals(ss[ss.Length - 1 - k], segs[segs.Length - 1 - k], StringComparison.OrdinalIgnoreCase)) k++;
                        if (k > best) { best = k; hit = s; }
                    }
                    if (best < 2 && cands.Count > 1) hit = null;     // the same file name in several folders, nothing else to go on
                }
            }
            if (hit == null) {
                string hint = e.Hint;
                if (hint.Length == 0 && e.Path.Length > 0) {
                    try { hint = Regex.Replace(System.IO.Path.GetFileNameWithoutExtension(e.Path), @"^\d+[\s.\-_]*", ""); } catch (Exception) { }
                }
                int d = hint.IndexOf(" - ");
                if (d > 0) byTag.TryGetValue(Norm(hint.Substring(0, d)) + "|" + Norm(hint.Substring(d + 3)), out hit);
            }
            if (hit != null) found.Add(hit);
            else notFound.Add(e.Hint.Length > 0 ? e.Hint : e.Path);
        }
        return found;
    }
}

// Writes the playlists. A file is only rewritten when what it would hold has changed.
public static class PmWrite {
    public static string Relative(string folder, string file) {
        string a = System.IO.Path.GetFullPath(folder).TrimEnd('\\'), b = System.IO.Path.GetFullPath(file);
        if (!string.Equals(System.IO.Path.GetPathRoot(a), System.IO.Path.GetPathRoot(b), StringComparison.OrdinalIgnoreCase)) return null;
        var fa = a.Split('\\'); var fb = b.Split('\\');
        int i = 0;
        while (i < fa.Length && i < fb.Length - 1 && string.Equals(fa[i], fb[i], StringComparison.OrdinalIgnoreCase)) i++;
        var sb = new StringBuilder();
        for (int k = i; k < fa.Length; k++) sb.Append("..\\");
        sb.Append(string.Join("\\", fb, i, fb.Length - i));
        return sb.ToString();
    }

    static string Ref(string folder, string path, string style) {
        if (style == "Full") return path;
        string r = Relative(folder, path);
        if (r == null) return path;                 // another drive: only a full path can reach it
        return style == "Slash" ? r.Replace('\\', '/') : r;
    }

    public static byte[] Bytes(PmList l, string style) {
        var sb = new StringBuilder("#EXTM3U\r\n");
        foreach (var s in l.Songs) {
            sb.Append("#EXTINF:").Append(s.Seconds > 0 ? s.Seconds : -1).Append(',').Append(s.Line).Append("\r\n");
            sb.Append(Ref(l.Folder, s.Path, style)).Append("\r\n");
        }
        bool utf8 = l.File.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase);
        return (utf8 ? new UTF8Encoding(false) : Encoding.Default).GetBytes(sb.ToString());
    }

    static bool Same(string file, byte[] b) {
        var fi = new FileInfo(file);
        if (!fi.Exists || fi.Length != b.Length) return false;
        var old = System.IO.File.ReadAllBytes(file);
        for (int i = 0; i < b.Length; i++) if (old[i] != b[i]) return false;
        return true;
    }

    public static void Check(List<PmList> lists, string style) {
        foreach (var l in lists) {
            try { l.State = !System.IO.File.Exists(l.File) ? "New" : Same(l.File, Bytes(l, style)) ? "Up to date" : "Changed"; }
            catch (Exception) { l.State = "New"; }
        }
    }

    // 0 = already up to date, 1 = new, 2 = changed.
    public static int Save(PmList l, string style) {
        var b = Bytes(l, style);
        bool had = System.IO.File.Exists(l.File);
        if (had && Same(l.File, b)) return 0;
        Directory.CreateDirectory(l.Folder);
        System.IO.File.WriteAllBytes(l.File, b);
        return had ? 2 : 1;
    }
}
'@
}
#endregion TAGS

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
Playlist Maker reads the tags of the MP3s in your music folders and makes playlists from them: one for each decade, each genre and each artist, and mixes such as "1980s Rock". It only writes playlist files; your music is only read, never changed.

1. ADD YOUR MUSIC FOLDERS
Add folder... adds a folder of music (everything under it is read, folders inside folders too). Remove folder takes the selected one off the list; nothing on the disk is touched.

2. READ MUSIC
Press Read music. The first time it reads every MP3, which can take a few minutes for a big collection (longer from a NAS). It remembers what it read, so next time only new and changed files are read. Stop ends a read early.

3. CHECK THE LIST
The list shows every playlist that would be made, how many songs it has and how long it plays. "New" playlists don't exist yet, "Changed" ones will be updated and "Up to date" ones are left alone. The buttons above the list show one kind at a time, and the search box finds a playlist by name. Double-click a playlist to see its songs.

4. SAVE PLAYLISTS
Save playlists writes them. Playlists it made before that are no longer wanted (an artist with too few songs now, say) go to the Recycle Bin. If a playlist with the same name is already there and Playlist Maker didn't make it, it asks before replacing it; if you keep it, it is left alone from then on (shown as Kept), and you aren't asked again.

IMPORTING PLAYLISTS
Import playlists... brings in playlists you already have (.m3u, .m3u8, .pls, .wpl, .zpl and .xspf), after Read music. Each song is found in your music folders: the same file, or the same file in the same folders on another drive, PC or NAS, or else the same artist and title. Songs that can't be found are listed and left out. An imported playlist keeps its own order and name, shows under Imported, and is saved with the others in your choice of paths and file type, beside the music folder most of its songs are in. Importing one with the same name again replaces it. To drop one, double-click it and press Remove import; the next save sends its file to the Recycle Bin.

GENRE GROUPS
A group puts several genres in one playlist, such as "Dance floor" (Dance, Disco, House, Trance ...) or "All Rock" (every kind of rock and metal). Edit groups... changes them: one group per line, its name, an equals sign, then its genres separated by commas. "Start again from the usual groups" puts the starting groups back.

SHUFFLES
A shuffle is a random pick of so many songs, such as 100. Type the sizes you want, separated by commas (10, 15, 25, 50, 100, 250); each makes its own playlist ("Shuffle - 100 songs"). It is a new pick each time the list is worked out, so each save gives you a fresh one.

LEAVING OUT GENRES
Songs with any of the genres listed under "Leave out songs of these genres" (Spoken Word, Comedy and the like) are left out of every playlist made here, but not out of imported ones.

PLAYLISTS TO MAKE
Tick the kinds you want. "Fewest songs in a playlist" leaves out small ones, such as an artist with only one or two songs. A song with several genres (Rock;Pop) goes in each of them.

WHICH TAGS ARE USED
Decades come from the year tag: everything before 1950 shares one playlist ("Before 1950"), then there is one for each decade from the 1950s to the 2000s, and everything from 2010 on shares "2010 onwards". When a song has an original year as well (a remaster or a best-of, say), that one is used, so a 1979 song on a 2011 reissue goes in the 1970s. Artist playlists go by the song's artist ("feat." guests are left off) or, if you choose, by the album artist. "Various Artists" never gets a playlist of its own. Songs with no year, genre or artist are left out of those playlists; the status bar says how many, and clicking it lists them so you can fix their tags.

PATHS IN THE PLAYLISTS
Relative paths (the default) are written from the playlist to the song, such as ..\Artist\Album\01 Song.mp3. They keep working when the music folder is copied to a NAS, another PC or a phone, as long as the playlists stay in the same place within it. "For NAS and phones" writes them with / instead of \, which some NAS and phone players need. Full paths (C:\Users\You\Music\...) only work on this PC. A song on a different drive from the playlist always gets a full path.

FILE TYPE
.m3u8 is saved as UTF-8 and keeps names with accents (Beyoncé, Motörhead) right. Use .m3u only for an old player that won't open .m3u8; letters it can't store are written as ?.

WHERE THEY ARE SAVED
You decide. "A folder I choose" (the usual way) puts all the playlists in one folder you pick: the first Save playlists asks for it, and Choose... changes it. "A folder inside each music folder" instead gives each music folder its own playlists, in a folder inside it (Playlists, unless you name another), made from that folder's songs only. Changing where they go moves them: the next save puts them in the new place and sends the old ones to the Recycle Bin.

LOOK
The Look button switches between Light, Dark and the same as Windows, from the next start.
'@

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="660" Height="620" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "$script:AppName Help"
    # Headings in bold: the lines written in capitals.
    $tb = $w.FindName('HelpText')
    foreach ($line in ($script:HelpText -split "`r?`n")) {
        if ($tb.Inlines.Count) { $tb.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
        $run = New-Object Windows.Documents.Run $line
        if ($line -cmatch '^[0-9. ]*[A-Z][A-Z ]+$') { $run.FontWeight = 'SemiBold'; $run.Foreground = Get-Brush 'Accent' }
        $tb.Inlines.Add($run)
    }
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Genre groups: edited as text, one group per line
# ---------------------------------------------------------------------------
function Show-GroupEditor {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="520" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="20,16,20,14">
    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,10">
      One group per line: its name, an equals sign, then the genres in it, separated by commas. A song is in a group when one of its genres is listed (capitals don't matter). Each group makes a playlist called "Group - name".
    </TextBlock>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="GeReset" DockPanel.Dock="Left" Content="Start again from the usual groups"/>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="GeSave" Content="Save" Style="{StaticResource Accent}" MinWidth="80" IsDefault="False"/>
        <Button x:Name="GeCancel" Content="Cancel" MinWidth="80" Margin="0" IsCancel="True"/>
      </StackPanel>
      <TextBlock/>
    </DockPanel>
    <TextBox x:Name="GeText" AcceptsReturn="True" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" Padding="10,8"/>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'Genre groups'
    $box = $w.FindName('GeText')
    $box.Text = ([string]$script:Settings.GroupText) -replace "`r?`n", "`r`n"
    $w.FindName('GeReset').Add_Click({ $box.Text = $script:DefaultGroups -replace "`r?`n", "`r`n" })
    $w.FindName('GeCancel').Add_Click({ $w.Close() })
    $w.FindName('GeSave').Add_Click({
        $script:Settings.GroupText = ($box.Text -replace "`r", '').Trim()
        Save-AppSetting
        $n = [PmBuild]::ParseGroups($script:Settings.GroupText).Count
        $w.Close()
        Update-Plan
        Set-Status "Saved $n genre group$(if ($n -ne 1) { 's' })."
    })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  A list of songs (a playlist's songs, or the songs missing tags)
# ---------------------------------------------------------------------------
function Show-SongList {
    param([string]$Title, [string]$Heading, $Songs, $Imported)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="620" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="18,16,18,14">
    <TextBlock x:Name="SlHead" DockPanel.Dock="Top" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap" Margin="4,0,0,10"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <Button x:Name="SlClose" DockPanel.Dock="Right" Content="Close" MinWidth="80" Margin="0" IsCancel="True" IsDefault="True"/>
      <Button x:Name="SlOpen" DockPanel.Dock="Right" Content="Show in Explorer" IsEnabled="False"/>
      <Button x:Name="SlForget" DockPanel.Dock="Right" Content="Remove import" Visibility="Collapsed"/>
      <TextBlock x:Name="SlNote" Foreground="{Soft}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="4,0,12,0"/>
    </DockPanel>
    <ListBox x:Name="SlList" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
      <ListBox.ItemTemplate><DataTemplate>
        <StackPanel>
          <TextBlock Text="{Binding Line}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding Info}" Foreground="{Soft}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
        </StackPanel>
      </DataTemplate></ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = $Title
    $w.FindName('SlHead').Text = $Heading
    $list = $w.FindName('SlList'); $open = $w.FindName('SlOpen')
    $list.ItemsSource = $Songs
    $w.FindName('SlNote').Text = 'Double-click a song (or Show in Explorer) to see its file.'
    if ($Imported) {
        $forget = $w.FindName('SlForget')
        $forget.Visibility = 'Visible'
        $forget.ToolTip = 'Take this playlist out of Playlist Maker. The next save sends its file to the Recycle Bin.'
        if ($Imported.Missing -eq 1) { $w.FindName('SlNote').Text = "1 of its songs wasn't found in your music folders, so it's left out." }
        elseif ($Imported.Missing) { $w.FindName('SlNote').Text = "$($Imported.Missing) of its songs weren't found in your music folders, so they're left out." }
        $forget.Add_Click({
            $script:Imports = @($script:Imports | Where-Object { $_.Name -ne $Imported.Name })
            Save-Imports
            Update-Plan
            Set-Status "Removed the import $($Imported.Name). Save playlists to tidy away its file."
            [Windows.Window]::GetWindow($this).Close()
        })
    }
    $list.Add_SelectionChanged({ $open.IsEnabled = [bool]$list.SelectedItem })
    $show = { if ($list.SelectedItem) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($list.SelectedItem.Path)`"" } }
    $open.Add_Click($show)
    $list.Add_MouseDoubleClick($show)
    $w.FindName('SlClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1230" Height="780" MinWidth="900" MinHeight="560" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel x:Name="Root">
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="0,1,0,0" Padding="18,12" MinHeight="64">
      <DockPanel VerticalAlignment="Center">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnOpen" Content="Open playlists folder" IsEnabled="False"/>
          <Button x:Name="BtnLook"/>
          <Button x:Name="BtnHelp" Content="Help"/>
          <Button x:Name="BtnAbout" Content="About" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextWrapping="Wrap" LineHeight="20" Foreground="{Soft}" Margin="0,0,16,0"/>
      </DockPanel>
    </Border>
    <ProgressBar x:Name="Progress" DockPanel.Dock="Bottom" Height="3" Foreground="{Accent}" Background="{Line}" BorderThickness="0" Visibility="Hidden"/>
    <Grid Margin="18,16,18,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="420"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- Left: music folders and options -->
      <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="18,4,18,18">
            <TextBlock Text="Music folders" Style="{StaticResource Head}" Margin="0,14,0,6"/>
            <Border BorderBrush="{Line}" BorderThickness="1" CornerRadius="6" Background="{Field}">
              <Grid MinHeight="92">
                <TextBlock x:Name="TxtNoFolders" Text="No folders yet: press Add folder..." Foreground="{Soft}" Margin="10,8" TextWrapping="Wrap"/>
                <ListBox x:Name="LstFolders" BorderThickness="0" Background="Transparent" MaxHeight="150" Margin="2" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
              </Grid>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="BtnAdd" Content="Add folder..."/>
              <Button x:Name="BtnRemove" Content="Remove folder" IsEnabled="False" Margin="0"/>
            </StackPanel>

            <TextBlock Text="Playlists to make" Style="{StaticResource Head}"/>
            <CheckBox x:Name="ChkDecades" Content="Decades (Before 1950 ... 2010 onwards)"/>
            <CheckBox x:Name="ChkGenres" Content="One for each genre"/>
            <CheckBox x:Name="ChkArtists" Content="One for each artist"/>
            <CheckBox x:Name="ChkMixes" Content="Decade and genre mixes (1980s Rock ...)"/>
            <DockPanel>
              <Button x:Name="BtnGroups" DockPanel.Dock="Right" Content="Edit groups..." Margin="8,6,0,0" Padding="10,4"/>
              <CheckBox x:Name="ChkGroups" Content="Genre groups (Dance floor ...)"/>
            </DockPanel>
            <DockPanel Margin="0,8,0,0">
              <CheckBox x:Name="ChkShuffles" DockPanel.Dock="Left" Content="Shuffles of" Margin="0"/>
              <TextBlock DockPanel.Dock="Right" Text="songs" VerticalAlignment="Center" Margin="8,0,0,0"/>
              <TextBox x:Name="TxtShuffles" Height="32" Margin="10,0,0,0" ToolTip="How many songs in each shuffle, such as 10, 15, 25, 50, 100, 250. Each size makes its own playlist."/>
            </DockPanel>
            <DockPanel Margin="0,12,0,0">
              <TextBox x:Name="TxtMin" DockPanel.Dock="Right" Width="64" Height="32" TextAlignment="Center" MaxLength="4"/>
              <TextBlock Text="Fewest songs in a playlist" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock Text="Leave out songs of these genres" Style="{StaticResource Label}"/>
            <TextBox x:Name="TxtSkip" Height="32" Margin="0,4,0,0" ToolTip="Songs with any of these genres are left out of the playlists made here (not of imported ones). Separate them with commas."/>

            <TextBlock Text="Options" Style="{StaticResource Head}"/>
            <TextBlock Text="Songs in order of" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbOrder">
              <ComboBoxItem Tag="Artist" Content="Artist, album and track"/>
              <ComboBoxItem Tag="Year" Content="Year, oldest first"/>
              <ComboBoxItem Tag="Title" Content="Song title"/>
              <ComboBoxItem Tag="Shuffle" Content="Shuffled (new order each save)"/>
            </ComboBox>
            <TextBlock Text="Artist playlists go by" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbArtist">
              <ComboBoxItem Tag="Artist" Content="The song's artist"/>
              <ComboBoxItem Tag="AlbumArtist" Content="The album artist"/>
            </ComboBox>
            <TextBlock Text="Paths in the playlists" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbPaths">
              <ComboBoxItem Tag="Relative" Content="Relative (..\Artist\Song.mp3)"/>
              <ComboBoxItem Tag="Slash" Content="Relative, for NAS and phones (../Artist/Song.mp3)"/>
              <ComboBoxItem Tag="Full" Content="Full paths (only work on this PC)"/>
            </ComboBox>
            <TextBlock Text="File type" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbType">
              <ComboBoxItem Tag=".m3u8" Content=".m3u8 (UTF-8, keeps accents right)"/>
              <ComboBoxItem Tag=".m3u" Content=".m3u (for older players)"/>
            </ComboBox>
            <TextBlock Text="Save playlists to" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbSave">
              <ComboBoxItem Tag="One" Content="A folder I choose"/>
              <ComboBoxItem Tag="Each" Content="A folder inside each music folder"/>
            </ComboBox>
            <DockPanel x:Name="PanelSub" Margin="0,8,0,0">
              <TextBlock Text="Folder name" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="{Soft}" Margin="0,0,10,0"/>
              <TextBox x:Name="TxtSub" Height="32"/>
            </DockPanel>
            <DockPanel x:Name="PanelOne" Margin="0,8,0,0">
              <Button x:Name="BtnOne" DockPanel.Dock="Right" Content="Choose..." Margin="8,0,0,0"/>
              <TextBox x:Name="TxtOne" Height="32" IsReadOnly="True"/>
            </DockPanel>
          </StackPanel>
        </ScrollViewer>
      </Border>

      <!-- Right: the playlists that would be made -->
      <DockPanel Grid.Column="1" Margin="14,0,0,0">
        <DockPanel DockPanel.Dock="Top">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnImport" Content="Import playlists..." ToolTip="Bring in playlists you already have (.m3u, .m3u8, .pls, .wpl, .xspf)"/>
            <Button x:Name="BtnRead" Content="Read music" Style="{StaticResource Accent}" MinWidth="110"/>
            <Button x:Name="BtnSave" Content="Save playlists" Style="{StaticResource Accent}" MinWidth="120" Margin="0" IsEnabled="False"/>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Playlists" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtSummary" Foreground="{Soft}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,14,0,4">
          <Grid DockPanel.Dock="Right" Width="210" VerticalAlignment="Top">
            <TextBox x:Name="TxtSearch" Height="32" ToolTip="Find a playlist by name"/>
            <StackPanel x:Name="TxtSearchHint" Orientation="Horizontal" Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False">
              <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{Soft}" VerticalAlignment="Center" Margin="0,1,8,0"/>
              <TextBlock Text="Find a playlist" Foreground="{Soft}" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>
          <WrapPanel VerticalAlignment="Center" Margin="0,0,10,0">
            <RadioButton x:Name="PillAll" Style="{StaticResource Pill}" GroupName="Kind" Tag="" IsChecked="True" Content="All"/>
            <RadioButton x:Name="PillDecade" Style="{StaticResource Pill}" GroupName="Kind" Tag="Decade" Content="Decades"/>
            <RadioButton x:Name="PillGenre" Style="{StaticResource Pill}" GroupName="Kind" Tag="Genre" Content="Genres"/>
            <RadioButton x:Name="PillArtist" Style="{StaticResource Pill}" GroupName="Kind" Tag="Artist" Content="Artists"/>
            <RadioButton x:Name="PillMix" Style="{StaticResource Pill}" GroupName="Kind" Tag="Mix" Content="Mixes"/>
            <RadioButton x:Name="PillGroup" Style="{StaticResource Pill}" GroupName="Kind" Tag="Group" Content="Groups"/>
            <RadioButton x:Name="PillShuffle" Style="{StaticResource Pill}" GroupName="Kind" Tag="Shuffle" Content="Shuffles"/>
            <RadioButton x:Name="PillImported" Style="{StaticResource Pill}" GroupName="Kind" Tag="Imported" Content="Imported"/>
          </WrapPanel>
        </DockPanel>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="6">
          <Grid>
            <TextBlock x:Name="TxtEmpty" Foreground="{Soft}" FontSize="14" TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="40"/>
            <ListBox x:Name="LstPlans" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
              <ListBox.ItemTemplate><DataTemplate>
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="12,0,4,0">
                    <TextBlock Text="{Binding Info}" HorizontalAlignment="Right"/>
                    <TextBlock Text="{Binding State}" HorizontalAlignment="Right" FontSize="12" Foreground="{Soft}"/>
                  </StackPanel>
                  <StackPanel>
                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Where}" Foreground="{Soft}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                  </StackPanel>
                </DockPanel>
              </DataTemplate></ListBox.ItemTemplate>
            </ListBox>
          </Grid>
        </Border>
      </DockPanel>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

$script:Songs = $null      # what the last Read music found
$script:Imports = @()      # playlists you imported (read at the start)
$script:Plan  = $null      # the playlists that would be made from it
$script:Missing = $null    # songs with no year, genre or artist

function Set-Status([string]$Text, [string]$Tone = 'Soft', [scriptblock]$OnClick) {
    $ui = $script:UI
    $ui.TxtStatus.Text = $Text
    $ui.TxtStatus.Foreground = Get-Brush $Tone
    $script:StatusClick = $OnClick
    $ui.TxtStatus.Cursor = if ($OnClick) { [Windows.Input.Cursors]::Hand } else { $null }
    # Assigned directly: an if-expression would unroll the decoration collection.
    if ($OnClick) { $ui.TxtStatus.TextDecorations = [Windows.TextDecorations]::Underline } else { $ui.TxtStatus.TextDecorations = $null }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

function Update-Render {
    <# Lets the window repaint (the status line) before a long job on this thread. #>
    $script:Window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Background)
}

# ---------------------------------------------------------------------------
#  Folders and options
# ---------------------------------------------------------------------------
function Show-Folders {
    $ui = $script:UI
    $ui.LstFolders.Items.Clear()
    foreach ($f in $script:Settings.Folders) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $f; $t.TextTrimming = 'CharacterEllipsis'; $t.ToolTip = $f
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $t; $item.Tag = $f
        [void]$ui.LstFolders.Items.Add($item)
    }
    $ui.TxtNoFolders.Visibility = if ($script:Settings.Folders.Count) { 'Collapsed' } else { 'Visible' }
    $ui.BtnRemove.IsEnabled = $false
}

function Add-MusicFolder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose a folder of music. Everything under it is read, folders inside folders too.'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $new = $dlg.SelectedPath.TrimEnd('\')
    if ($new.Length -eq 2) { $new += '\' }    # a whole drive, such as D:\
    foreach ($f in $script:Settings.Folders) {
        $a = $f.TrimEnd('\') + '\'; $b = $new.TrimEnd('\') + '\'
        if ($a -eq $b) { Set-Status "$new is already in the list."; return }
        if ($b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase) -or $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) {
            [void](Show-AppMessage "$new and $f are one inside the other, so their songs would be read twice.`n`nKeep just the outer folder, or remove it first and add the inner one.")
            return
        }
    }
    $script:Settings.Folders = @($script:Settings.Folders) + $new
    Save-AppSetting
    Show-Folders
    Clear-Read "Added $new. Press Read music to read it."
}

function Remove-MusicFolder {
    $f = [string]$script:UI.LstFolders.SelectedItem.Tag
    if (-not $f) { return }
    $script:Settings.Folders = @($script:Settings.Folders | Where-Object { $_ -ne $f })
    Save-AppSetting
    Show-Folders
    Clear-Read "Removed $f from the list (nothing on the disk was changed). Press Read music to read the rest."
}

function Clear-Read([string]$Message) {
    <# The folders changed, so what was read no longer matches them. #>
    $script:Songs = $null; $script:Plan = $null; $script:Missing = $null
    Show-Plan
    Set-Status $Message
}

function Get-Options {
    $s = $script:Settings
    $o = New-Object PmOptions
    $o.Decades = $s.Decades; $o.Genres = $s.Genres; $o.Artists = $s.Artists; $o.Mixes = $s.Mixes
    $o.Groups = $s.Groups; $o.Shuffles = $s.Shuffles; $o.GroupText = [string]$s.GroupText; $o.Skip = [string]$s.SkipGenres; $o.ShuffleSizes = [string]$s.ShuffleSizes
    $o.Min = [Math]::Max(1, [int]$s.MinSongs)
    $o.Order = $s.Order; $o.AlbumArtist = ($s.ArtistFrom -eq 'AlbumArtist'); $o.Ext = $s.FileType
    $o.Each = ($s.SaveTo -ne 'One'); $o.SubFolder = $s.SubFolder; $o.OneFolder = [string]$s.OneFolder
    if (-not $o.Each -and -not $o.OneFolder) { $o.OneFolder = $script:NotChosen }   # asked for when saving
    $o.Roots = [string[]]@($s.Folders)
    return $o
}

function Select-ComboTag($Combo, [string]$Tag) {
    $pick = @($Combo.Items | Where-Object { $_.Tag -eq $Tag }) | Select-Object -First 1
    $Combo.SelectedItem = if ($pick) { $pick } else { $Combo.Items[0] }
}

function Show-Options {
    <# Puts the saved settings into the controls (before their change events are wired up). #>
    $ui = $script:UI; $s = $script:Settings
    $ui.ChkDecades.IsChecked = $s.Decades; $ui.ChkGenres.IsChecked = $s.Genres
    $ui.ChkArtists.IsChecked = $s.Artists; $ui.ChkMixes.IsChecked = $s.Mixes
    $ui.TxtMin.Text = [string]$s.MinSongs
    $ui.ChkGroups.IsChecked = $s.Groups; $ui.ChkShuffles.IsChecked = $s.Shuffles
    $ui.TxtShuffles.Text = [string]$s.ShuffleSizes; $ui.TxtSkip.Text = [string]$s.SkipGenres
    Select-ComboTag $ui.CmbOrder $s.Order
    Select-ComboTag $ui.CmbArtist $s.ArtistFrom
    Select-ComboTag $ui.CmbPaths $s.Paths
    Select-ComboTag $ui.CmbType $s.FileType
    Select-ComboTag $ui.CmbSave $s.SaveTo
    $ui.TxtSub.Text = $s.SubFolder
    Show-OneFolder
    Show-SavePanel
}

$script:NotChosen = '(not chosen yet)'

function Show-OneFolder {
    $script:UI.TxtOne.Text = if ($script:Settings.OneFolder) { $script:Settings.OneFolder } else { "Not chosen yet: you'll be asked when you save" }
}

function Select-PlaylistFolder {
    <# Asks where the playlists go; $true when a folder was picked. #>
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder to save the playlists in. A new, empty folder (such as Playlists) keeps them tidy.'
    if ($script:Settings.OneFolder) { $dlg.SelectedPath = $script:Settings.OneFolder }
    if ($dlg.ShowDialog() -ne 'OK') { return $false }
    $script:Settings.OneFolder = $dlg.SelectedPath
    Save-AppSetting
    Show-OneFolder
    Update-Plan
    Set-Status "Playlists will be saved in $($dlg.SelectedPath)."
    return $true
}

function Show-SavePanel {
    $each = $script:Settings.SaveTo -ne 'One'
    $script:UI.PanelSub.Visibility = if ($each) { 'Visible' } else { 'Collapsed' }
    $script:UI.PanelOne.Visibility = if ($each) { 'Collapsed' } else { 'Visible' }
}

function Read-Options {
    <# The controls back into the settings, then the list is worked out again. #>
    $ui = $script:UI; $s = $script:Settings
    $s.Decades = [bool]$ui.ChkDecades.IsChecked; $s.Genres = [bool]$ui.ChkGenres.IsChecked
    $s.Artists = [bool]$ui.ChkArtists.IsChecked; $s.Mixes = [bool]$ui.ChkMixes.IsChecked
    $n = 0
    if ([int]::TryParse($ui.TxtMin.Text.Trim(), [ref]$n) -and $n -ge 1) { $s.MinSongs = $n }
    $s.Groups = [bool]$ui.ChkGroups.IsChecked; $s.Shuffles = [bool]$ui.ChkShuffles.IsChecked
    $s.ShuffleSizes = $ui.TxtShuffles.Text.Trim(); $s.SkipGenres = $ui.TxtSkip.Text.Trim()
    $s.Order = [string]$ui.CmbOrder.SelectedItem.Tag
    $s.ArtistFrom = [string]$ui.CmbArtist.SelectedItem.Tag
    $s.Paths = [string]$ui.CmbPaths.SelectedItem.Tag
    $s.FileType = [string]$ui.CmbType.SelectedItem.Tag
    $s.SaveTo = [string]$ui.CmbSave.SelectedItem.Tag
    $sub = ($ui.TxtSub.Text.Trim() -replace '[\\/:*?"<>|]', '').Trim('.', ' ')
    if ($sub) { $s.SubFolder = $sub }
    Save-AppSetting
    Show-SavePanel
    Update-Plan
}

# ---------------------------------------------------------------------------
#  The list of playlists
# ---------------------------------------------------------------------------
function Update-Plan {
    <# Works out the playlists from the songs read and the options, and which are new or changed. #>
    if ($null -eq $script:Songs) { $script:Plan = $null; Show-Plan; return }
    $o = Get-Options
    $script:Plan = [PmBuild]::Make($script:Songs, $o)
    if (@($script:Imports).Count) {
        $byPath = [PmBuild]::PathIndex($script:Songs)
        foreach ($imp in $script:Imports) { [PmBuild]::AddImported($script:Plan, $byPath, $o, [string]$imp.Name, [string[]]@($imp.Paths), @($imp.NotFound).Count) }
    }
    Update-State
    Show-Plan
}

function Update-State {
    <# New, Changed or Up to date for each playlist, and "Kept" for one you chose to keep. #>
    [PmWrite]::Check($script:Plan, $script:Settings.Paths)
    $kept = Get-NameSet $script:KeptPath
    $made = Get-NameSet $script:MadePath
    foreach ($l in $script:Plan) { if ($kept.Contains($l.File) -and -not $made.Contains($l.File) -and (Test-Path -LiteralPath $l.File)) { $l.State = 'Kept (not made here)' } }
}

function Show-Plan {
    $ui = $script:UI
    $plan = $script:Plan
    # One pass for the counts (a big collection can make thousands of artist playlists).
    $count = @{ '' = 0; Decade = 0; Genre = 0; Artist = 0; Mix = 0; Group = 0; Shuffle = 0; Imported = 0; New = 0; Changed = 0; 'Up to date' = 0; Kept = 0 }
    if ($null -ne $plan) {
        foreach ($l in $plan) {
            $count[''] += 1; $count[$l.Kind] += 1
            if ($l.State -like 'Kept*') { $count.Kept += 1 } elseif ($count.ContainsKey($l.State)) { $count[$l.State] += 1 }
        }
    }
    # A pill for each kind that is ticked; a hidden pill that was picked goes back to All.
    $kinds = @{ '' = 'All'; Decade = 'Decades'; Genre = 'Genres'; Artist = 'Artists'; Mix = 'Mixes'; Group = 'Groups'; Shuffle = 'Shuffles'; Imported = 'Imported' }
    $ticked = @{ '' = $true; Decade = $script:Settings.Decades; Genre = $script:Settings.Genres; Artist = $script:Settings.Artists; Mix = $script:Settings.Mixes
                 Group = $script:Settings.Groups; Shuffle = $script:Settings.Shuffles
                 Imported = ($count.Imported -gt 0 -or @($script:Imports).Count -gt 0) }
    foreach ($p in 'PillAll', 'PillDecade', 'PillGenre', 'PillArtist', 'PillMix', 'PillGroup', 'PillShuffle', 'PillImported') {
        $k = [string]$ui[$p].Tag
        $ui[$p].Content = if ($null -ne $plan) { "$($kinds[$k])  $($count[$k])" } else { $kinds[$k] }
        $ui[$p].Visibility = if ($ticked[$k]) { 'Visible' } else { 'Collapsed' }
        if (-not $ticked[$k] -and $ui[$p].IsChecked) { $ui.PillAll.IsChecked = $true }
    }
    $ui.BtnSave.IsEnabled = ($null -ne $plan -and $plan.Count -gt 0)
    $ui.BtnOpen.IsEnabled = [bool](Get-PlaylistFolder)
    if ($null -eq $plan) {
        $ui.LstPlans.ItemsSource = $null
        $ui.TxtSummary.Text = ''
        $ui.TxtEmpty.Visibility = 'Visible'
        $ui.TxtEmpty.Text = if (-not $script:Settings.Folders.Count) { 'Add your music folders on the left, then press Read music.' }
                            else { 'Press Read music to see the playlists your songs make.' }
        return
    }
    $new = $count.New; $chg = $count.Changed; $ok = $count['Up to date']; $kp = $count.Kept
    $bits = @(); if ($new) { $bits += "$new new" }; if ($chg) { $bits += "$chg changed" }; if ($ok) { $bits += "$ok up to date" }; if ($kp) { $bits += "$kp kept" }
    $ui.TxtSummary.Text = "$('{0:N0}' -f $plan.Count) playlist$(if ($plan.Count -ne 1) { 's' }) from $('{0:N0}' -f $script:Songs.Count) songs" + $(if ($bits) { ':  ' + ($bits -join ', ') } else { '' })

    $kind = [string](@('PillAll', 'PillDecade', 'PillGenre', 'PillArtist', 'PillMix', 'PillGroup', 'PillShuffle', 'PillImported' | Where-Object { $ui[$_].IsChecked } | ForEach-Object { $ui[$_].Tag }) | Select-Object -First 1)
    $find = $ui.TxtSearch.Text.Trim()
    $shown = New-Object 'System.Collections.Generic.List[PmList]'
    foreach ($l in $plan) {
        if ($kind -and $l.Kind -ne $kind) { continue }
        if ($find -and $l.Name.IndexOf($find, [StringComparison]::CurrentCultureIgnoreCase) -lt 0) { continue }
        $shown.Add($l)
    }
    $ui.LstPlans.ItemsSource = $shown
    $ui.TxtEmpty.Visibility = if ($shown.Count) { 'Collapsed' } else { 'Visible' }
    $ui.TxtEmpty.Text = if ($plan.Count -eq 0) { "No playlist has at least $($script:Settings.MinSongs) songs. Lower ""Fewest songs in a playlist"" or tick more kinds on the left." }
                        elseif ($find) { "No playlist matches ""$find""." } else { 'None of this kind.' }
}

function Get-PlaylistFolder {
    <# The folder Open playlists folder opens: the selected playlist's, or the first one that exists. #>
    $sel = $script:UI.LstPlans.SelectedItem
    if ($sel -and $sel.Folder -ne $script:NotChosen -and (Test-Path -LiteralPath $sel.Folder)) { return $sel.Folder }
    $s = $script:Settings
    $cands = if ($s.SaveTo -eq 'One') { @($s.OneFolder) } else { @($s.Folders | ForEach-Object { Join-Path $_ $s.SubFolder }) }
    return @($cands | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
}

# ---------------------------------------------------------------------------
#  Reading the music
# ---------------------------------------------------------------------------
function Start-Read {
    if ([PmScan]::Busy) { [PmScan]::Cancel = $true; Set-Status 'Stopping...'; return }
    $folders = @($script:Settings.Folders)
    if (-not $folders.Count) { Set-Status 'Add a music folder first (Add folder... on the left).' 'Warn'; return }
    $gone = @($folders | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($gone.Count -eq $folders.Count) { Set-Status "Can't reach $($gone -join ', '). Is the drive or NAS connected?" 'Bad'; return }
    $script:ReadStarted = Get-Date
    [PmScan]::Start([string[]]$folders, $script:CachePath)
    $ui = $script:UI
    $ui.BtnRead.Content = 'Stop'
    $ui.BtnSave.IsEnabled = $false
    $ui.Progress.Visibility = 'Visible'; $ui.Progress.IsIndeterminate = $true
    Set-Status 'Finding your MP3s...'
    Write-AppLog "Read started: $($folders -join '; ')"
}

function Update-Read {
    if (-not $script:ReadStarted) { return }
    $ui = $script:UI
    $now = [string][PmScan]::Now
    if ($now.Length -gt 80) { $now = '...' + $now.Substring($now.Length - 77) }
    if ([PmScan]::Busy) {
        if ([PmScan]::Phase -eq 'Finding') { Set-Status ('Finding your MP3s: {0:N0} so far  ·  {1}' -f [PmScan]::Found, $now) }
        else {
            $ui.Progress.IsIndeterminate = $false
            $ui.Progress.Maximum = [Math]::Max(1, [PmScan]::Found); $ui.Progress.Value = [PmScan]::Done
            Set-Status ('Reading tags: {0:N0} of {1:N0} songs  ·  {2}' -f [PmScan]::Done, [PmScan]::Found, $now)
        }
        return
    }
    $secs = [int]((Get-Date) - $script:ReadStarted).TotalSeconds
    $script:ReadStarted = $null
    $ui.BtnRead.Content = 'Read music'
    $ui.Progress.Visibility = 'Hidden'
    if ([PmScan]::Failure) { Set-Status "Couldn't read the music: $([PmScan]::Failure)" 'Bad'; Write-AppLog "Read failed: $([PmScan]::Failure)"; Show-Plan; return }
    if ([PmScan]::Cancel -or $null -eq [PmScan]::Songs) { Set-Status 'Stopped. Press Read music to start again.'; Show-Plan; return }

    $script:Songs = [PmScan]::Songs
    Update-Plan
    $songs = $script:Songs
    $time = if ($secs -ge 90) { "$([Math]::Round($secs / 60)) min" } elseif ($secs -ge 1) { "$secs s" } else { 'under a second' }
    $msg = 'Read {0:N0} songs in {1}' -f $songs.Count, $time
    if ([PmScan]::FromCache) { $msg += ' ({0:N0} unchanged since last time)' -f [PmScan]::FromCache }
    $msg += '.'
    $script:Missing = New-Object 'System.Collections.Generic.List[PmSong]'
    $noYear = 0; $noGenre = 0; $noArtist = 0
    foreach ($s in $songs) {
        $y = -not [PmBuild]::DecadeOf($s.Year); $g = -not $s.Genre; $a = -not $s.Artist
        if ($y) { $noYear++ }; if ($g) { $noGenre++ }; if ($a) { $noArtist++ }
        if ($y -or $g -or $a) { $script:Missing.Add($s) }
    }
    $bits = @(); if ($noYear) { $bits += "$('{0:N0}' -f $noYear) no year" }; if ($noGenre) { $bits += "$('{0:N0}' -f $noGenre) no genre" }; if ($noArtist) { $bits += "$('{0:N0}' -f $noArtist) no artist" }
    $problems = @([PmScan]::Problems)
    $tone = 'Soft'; $click = $null
    if ($bits) {
        $msg += " Missing tags: $($bits -join ', '). Click to see them."
        $tone = 'Warn'
        $click = { Show-SongList 'Songs missing tags' "$('{0:N0}' -f $script:Missing.Count) songs are missing a year, genre or artist, so they are left out of those playlists" $script:Missing }
    }
    if ($problems.Count) {
        $msg += " $($problems.Count) file$(if ($problems.Count -ne 1) { 's or folders' } else { ' or folder' }) couldn't be read$(if (-not $bits) { ': click for the list' })."
        $tone = 'Warn'
        if (-not $click) { $click = { [void](Show-AppMessage ("These couldn't be read:`n`n" + ((@([PmScan]::Problems) | Select-Object -First 25) -join "`n")) -Title 'Not read') } }
        Write-AppLog ("Not read: " + ($problems -join ' | '))
    }
    Set-Status $msg $tone $click
    Write-AppLog "$msg Playlists: $(@($script:Plan).Count)."
}

# ---------------------------------------------------------------------------
#  Saving the playlists
# ---------------------------------------------------------------------------
function Get-NameSet([string]$Path) {
    <# The playlist files listed in made.txt or kept.txt. #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $Path) {
        foreach ($l in [IO.File]::ReadAllLines($Path)) { if ($l.Trim()) { [void]$set.Add($l.Trim()) } }
    }
    return , $set
}

function Save-NameSet([string]$Path, $Set) {
    try { [IO.File]::WriteAllLines($Path, [string[]]@($Set)) } catch { Write-AppLog "$(Split-Path -Leaf $Path) couldn't be saved: $($_.Exception.Message)" }
}

function Save-Playlists {
    if (-not $script:Plan -or -not $script:Plan.Count) { return }
    # The first save asks where the playlists go.
    if ($script:Settings.SaveTo -eq 'One' -and -not $script:Settings.OneFolder) {
        if (-not (Select-PlaylistFolder)) { Set-Status 'Not saved: choose a folder for the playlists first.' 'Warn'; return }
    }
    $plan = $script:Plan
    if (-not $plan -or -not $plan.Count) { return }
    $style = $script:Settings.Paths
    $made = Get-NameSet $script:MadePath
    $kept = Get-NameSet $script:KeptPath
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # Playlists already there with the same name that this app didn't make: ask first, once.
    # Ones you chose to keep before are left alone without asking again.
    $others = @($plan | Where-Object { -not $made.Contains($_.File) -and (Test-Path -LiteralPath $_.File) })
    foreach ($t in $others) { if ($kept.Contains($t.File)) { [void]$skip.Add($t.File) } }
    $theirs = @($others | Where-Object { -not $kept.Contains($_.File) })
    if ($theirs.Count) {
        $names = ($theirs | Select-Object -First 5 | ForEach-Object { '  ' + [IO.Path]::GetFileName($_.File) }) -join "`n"
        $more = if ($theirs.Count -gt 5) { "`n  ... and $($theirs.Count - 5) more" } else { '' }
        $replace = Show-AppMessage "$($theirs.Count) playlist$(if ($theirs.Count -ne 1) { 's' }) with the same name already exist$(if ($theirs.Count -eq 1) { 's' }), made by something else:`n`n$names$more`n`nReplace $(if ($theirs.Count -eq 1) { 'it with the one' } else { 'them with the ones' }) Playlist Maker makes?" -Title 'Replace playlists?' -YesText 'Replace' -NoText 'Keep those'
        foreach ($t in $theirs) { if ($replace) { [void]$kept.Remove($t.File) } else { [void]$skip.Add($t.File); [void]$kept.Add($t.File) } }
        Save-NameSet $script:KeptPath $kept
    }

    Set-Status 'Saving playlists...'; Update-Render
    $new = 0; $changed = 0; $same = 0; $failed = 0
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $plan) {
        if ($skip.Contains($l.File)) { continue }
        try {
            switch ([PmWrite]::Save($l, $style)) { 0 { $same++ } 1 { $new++ } 2 { $changed++ } }
            [void]$wanted.Add($l.File)
        } catch { $failed++; Write-AppLog "Couldn't save $($l.File): $($_.Exception.Message)" }
    }

    # Ones made before that aren't wanted now go to the Recycle Bin.
    $binned = 0
    foreach ($old in $made) {
        if ($wanted.Contains($old) -or -not (Test-Path -LiteralPath $old)) { continue }
        if ([IO.Path]::GetExtension($old) -notin '.m3u', '.m3u8') { continue }
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($old, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $binned++
        } catch { [void]$wanted.Add($old); Write-AppLog "Couldn't recycle $($old): $($_.Exception.Message)" }
    }
    Save-NameSet $script:MadePath $wanted

    Update-State
    Show-Plan
    $bits = @()
    if ($new) { $bits += "$new new" }; if ($changed) { $bits += "$changed updated" }; if ($same) { $bits += "$same already up to date" }
    $msg = "Saved playlists: $($bits -join ', ')."
    if ($skip.Count) { $msg += " Kept $($skip.Count) with the same name that something else made." }
    if ($binned) { $msg += " $binned old one$(if ($binned -ne 1) { 's' }) no longer wanted went to the Recycle Bin." }
    if ($failed) { $msg += " $failed couldn't be saved (see the log)." }
    Set-Status $msg $(if ($failed) { 'Bad' } else { 'Good' })
    Write-AppLog $msg
}

# ---------------------------------------------------------------------------
#  Importing playlists
# ---------------------------------------------------------------------------
function Get-Imports {
    <# The imported playlists: name, where it came from, the songs it matched and what wasn't found. #>
    if (-not (Test-Path -LiteralPath $script:ImportsPath)) { return @() }
    try {
        $j = Get-Content -LiteralPath $script:ImportsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($j | Where-Object { $_.Name })     # piping the variable lists each playlist (5.1 hands an array over whole)
    }
    catch { Write-AppLog "imports.json couldn't be read: $($_.Exception.Message)"; return @() }
}

function Save-Imports {
    try { ConvertTo-Json -InputObject @($script:Imports) -Depth 4 | Set-Content -LiteralPath $script:ImportsPath -Encoding UTF8 }
    catch { Write-AppLog "imports.json couldn't be saved: $($_.Exception.Message)" }
}

function Import-Playlists {
    param([string[]]$Files)      # given: import these without asking (otherwise the Open box asks)
    if ($null -eq $script:Songs) {
        [void](Show-AppMessage 'Press Read music first, so the songs in the playlists can be found in your music folders.' -Title 'Import playlists')
        return
    }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Import playlists'
    $dlg.Filter = 'Playlists (*.m3u, *.m3u8, *.pls, *.wpl, *.zpl, *.xspf)|*.m3u;*.m3u8;*.pls;*.wpl;*.zpl;*.xspf|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    if (-not $Files) {
        if (-not $dlg.ShowDialog($script:Window)) { return }
        $Files = $dlg.FileNames
    }
    $done = @(); $failed = @(); $lost = New-Object 'System.Collections.Generic.List[string]'
    $found = 0; $total = 0
    foreach ($f in $Files) {
        try {
            $entries = [PmImport]::Parse($f)
            $miss = New-Object 'System.Collections.Generic.List[string]'
            $songs = [PmImport]::Match($entries, $script:Songs, $miss)
            $name = [IO.Path]::GetFileNameWithoutExtension($f)
            $script:Imports = @($script:Imports | Where-Object { $_.Name -ne $name }) + [pscustomobject]@{
                Name = $name; From = $f; Paths = @($songs | ForEach-Object { $_.Path }); NotFound = @($miss) }
            $found += $songs.Count; $total += $entries.Count
            foreach ($m in $miss) { $lost.Add("$($name):  $m") }
            $done += $name
            Write-AppLog "Imported $f : $($songs.Count) of $($entries.Count) found"
        } catch { $failed += [IO.Path]::GetFileName($f); Write-AppLog "Couldn't import $($f): $($_.Exception.Message)" }
    }
    Save-Imports
    Update-Plan
    if ($done.Count) { $script:UI.PillImported.IsChecked = $true }
    $msg = "Imported $($done.Count) playlist$(if ($done.Count -ne 1) { 's' }): $('{0:N0}' -f $found) of $('{0:N0}' -f $total) songs found in your music."
    if ($failed.Count) { $msg += " Couldn't read $($failed -join ', ')." }
    if ($lost.Count) {
        $list = ($lost | Select-Object -First 20) -join "`n"
        $more = if ($lost.Count -gt 20) { "`n... and $($lost.Count - 20) more" } else { '' }
        [void](Show-AppMessage "$msg`n`nThese weren't found, so they're left out:`n`n$list$more" -Title 'Import playlists')
    }
    Set-Status ($msg + ' Press Save playlists to save them.') $(if ($failed.Count -or $lost.Count) { 'Warn' } else { 'Soft' })
}

# ---------------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------------
try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    $window.Title = "$script:AppName v$script:AppVersion"
    # A roomy window: most of the screen, never smaller than 1230 x 780 (when the screen has room).
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width  = [Math]::Min($area.Width, [Math]::Max(1230, $area.Width * 0.88))
    $window.Height = [Math]::Min($area.Height, [Math]::Max(780, $area.Height * 0.88))
    # On a big screen everything is drawn larger too (text, buttons, lists), not just the window.
    $zoom = [Math]::Max(1.0, [Math]::Min(1.3, $area.Width / 1900.0))
    if ($zoom -gt 1.01) { $window.FindName('Root').LayoutTransform = New-Object Windows.Media.ScaleTransform $zoom, $zoom }
    $icon = Get-AssetImage 'Playlist-Maker.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnOpen', 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'Progress', 'TxtNoFolders', 'LstFolders', 'BtnAdd', 'BtnRemove', 'TxtSearchHint',
                   'ChkDecades', 'ChkGenres', 'ChkArtists', 'ChkMixes', 'ChkGroups', 'ChkShuffles', 'TxtShuffles', 'TxtSkip', 'BtnGroups', 'TxtMin', 'CmbOrder', 'CmbArtist', 'CmbPaths', 'CmbType', 'CmbSave',
                   'PanelSub', 'TxtSub', 'PanelOne', 'TxtOne', 'BtnOne', 'BtnRead', 'BtnSave', 'TxtSummary', 'TxtSearch',
                   'PillAll', 'PillDecade', 'PillGenre', 'PillArtist', 'PillMix', 'PillGroup', 'PillShuffle', 'PillImported', 'TxtEmpty', 'LstPlans', 'BtnImport') { $ui[$n] = $window.FindName($n) }
    $script:UI = $ui

    $script:Imports = @(Get-Imports)
    Show-Folders
    Show-Options
    Show-Plan

    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })
    $ui.BtnOpen.Add_Click({ Invoke-Safely { $f = Get-PlaylistFolder; if ($f) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$f`"" } } })

    $ui.BtnAdd.Add_Click({ Invoke-Safely { Add-MusicFolder } })
    $ui.BtnRemove.Add_Click({ Invoke-Safely { Remove-MusicFolder } })
    $ui.LstFolders.Add_SelectionChanged({ $ui.BtnRemove.IsEnabled = [bool]$ui.LstFolders.SelectedItem })

    foreach ($c in 'ChkDecades', 'ChkGenres', 'ChkArtists', 'ChkMixes', 'ChkGroups', 'ChkShuffles') {
        $ui[$c].Add_Checked({ Invoke-Safely { Read-Options } }); $ui[$c].Add_Unchecked({ Invoke-Safely { Read-Options } })
    }
    foreach ($c in 'CmbOrder', 'CmbArtist', 'CmbPaths', 'CmbType', 'CmbSave') { $ui[$c].Add_SelectionChanged({ Invoke-Safely { Read-Options } }) }
    # Typed boxes: worked out once typing pauses, not on every key.
    $typing = New-Object Windows.Threading.DispatcherTimer
    $typing.Interval = [TimeSpan]::FromMilliseconds(500)
    $typing.Add_Tick({ $typing.Stop(); Invoke-Safely { Read-Options } })
    $ui.TxtMin.Add_TextChanged({ $typing.Stop(); $typing.Start() })
    $ui.TxtShuffles.Add_TextChanged({ $typing.Stop(); $typing.Start() })
    $ui.TxtSkip.Add_TextChanged({ $typing.Stop(); $typing.Start() })
    $ui.BtnGroups.Add_Click({ Invoke-Safely { Show-GroupEditor } })
    $ui.TxtSub.Add_TextChanged({ $typing.Stop(); $typing.Start() })
    $ui.TxtMin.Add_PreviewTextInput({ param($s, $e) if ($e.Text -notmatch '^\d+$') { $e.Handled = $true } })
    $ui.BtnOne.Add_Click({ Invoke-Safely { [void](Select-PlaylistFolder) } })

    $searching = New-Object Windows.Threading.DispatcherTimer
    $searching.Interval = [TimeSpan]::FromMilliseconds(220)
    $searching.Add_Tick({ $searching.Stop(); Show-Plan })
    $ui.TxtSearch.Add_TextChanged({
        $ui.TxtSearchHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }
        $searching.Stop(); $searching.Start()
    })
    foreach ($p in 'PillAll', 'PillDecade', 'PillGenre', 'PillArtist', 'PillMix', 'PillGroup', 'PillShuffle', 'PillImported') { $ui[$p].Add_Checked({ if ($script:UI) { Show-Plan } }) }
    $ui.LstPlans.Add_MouseDoubleClick({
        $l = $ui.LstPlans.SelectedItem
        if ($l) { Show-SongList "$($l.Kind): $($l.Name)" "$($l.Name)  ·  $($l.Info)" $l.Songs $(if ($l.Kind -eq 'Imported') { $l }) }
    })
    $ui.LstPlans.Add_SelectionChanged({ $ui.BtnOpen.IsEnabled = [bool](Get-PlaylistFolder) })

    $ui.BtnRead.Add_Click({ Invoke-Safely { Start-Read } })
    $ui.BtnImport.Add_Click({ Invoke-Safely { Import-Playlists } })
    $ui.BtnSave.Add_Click({ Invoke-Safely { Save-Playlists } })
    $ui.TxtStatus.Add_MouseLeftButtonUp({ if ($script:StatusClick) { Invoke-Safely $script:StatusClick } })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ try { Update-Read } catch { Write-AppLog "Update: $($_.Exception.Message)" } })
    $window.Add_ContentRendered({
        $timer.Start()
        if ($script:Settings.Folders.Count) { Set-Status 'Press Read music to read your music folders.' }
        else { Set-Status 'Start by adding your music folders (Add folder... on the left).' }
    })
    $window.Add_Closing({ [PmScan]::Cancel = $true })
    $window.Add_Closed({ $timer.Stop() })
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}

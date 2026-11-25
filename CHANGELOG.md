# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.00] - 2026-11-25
First release.

### Added
- Reads the tags of the MP3s in your music folders (ID3v2.2, 2.3, 2.4 and ID3v1) and each song's running time, four files at a time in the background, with a Stop button.
- Makes a playlist for each decade, genre and artist, and decade-and-genre mixes, with a smallest-playlist size. Songs before 1950 share a "Before 1950" playlist and songs from 2010 on a "2010 onwards" one; original years count for decades; "feat." guests and Various Artists get no artist playlist.
- Genre groups (Dance floor, Chill, All Rock, Soul & Funk, Jazz & Swing, Ballads), edited in their own window.
- Shuffles of any number of songs (10, 15, 25, 50, 100, 250 by default), a fresh pick each save.
- Leave out songs of chosen genres (Spoken Word, Speech, Comedy, Trailer, Audiobook, Podcast by default).
- A list of the playlists before saving: songs, running time, and new, changed or up to date. Filter by kind, search, and double-click for the songs.
- Relative paths (with \ or /) or full paths; .m3u8 (UTF-8) or .m3u; saved in a folder you choose (asked on the first save) or in a folder inside each music folder.
- Only changed playlists are rewritten; old ones no longer wanted go to the Recycle Bin; same-named playlists made by something else are only replaced if you say so.
- Import playlists you already have (.m3u, .m3u8, .pls, .wpl, .zpl, .xspf): songs are matched by path, by the same folders on another drive or NAS, or by artist and title; the ones not found are listed. Imported playlists keep their order and are saved with the others.
- A tag cache, so later reads only open new and changed files.
- Songs missing a year, genre or artist are counted and can be listed.
- Light, dark and Follow Windows looks, Help and an About box.

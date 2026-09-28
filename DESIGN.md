---
version: alpha
colors:
  primary: "#138A91"
  archiveNavy: "#102B4F"
  archiveLight: "#A8DEE0"
  historyAmber: "#F9B84C"
typography:
  interface:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
  data:
    fontFamily: "SFMono, Menlo, monospace"
rounded:
  card: "12px"
omitted:
  - section: spacing
    reason: "Native SwiftUI controls own their platform spacing; shared CardModifier owns card padding."
  - section: components
    reason: "SwiftUI controls and Sources/Burrow/UI/Components.swift are the component source of truth."
---

## Overview

Burrow is a macOS backup and SFTP browser for people who need to know that their files are safe and recoverable. It should feel like a dependable storage tool: familiar Finder-like controls, clear backup status, and quiet detail. The file archive icon gives the app its own identity without making the file browser look branded at the expense of legibility.

## Colors

The icon owns the navy, teal and amber values above. The application uses macOS semantic backgrounds, text and accent color so light mode, dark mode and accessibility contrast remain native. Amber marks archived versions; status always has text and an icon as well as color. Theme constants in `Sources/Burrow/UI/Components.swift` own shared app surfaces.

## Typography

Use San Francisco through system font APIs for navigation and actions. Use monospaced digits for sizes, counts and dates where alignment helps scanning. Keep server paths selectable and available in full when truncated.

## Layout

The sidebar separates Servers, Transfers and Backup. A server opens into a browser with path controls, file content and a compact status line. Backup status shows one primary action, current health and the most recent run. Archive history opens beside the file being inspected; advanced connection details remain in settings.

## Elevation & Depth

Use native materials for transient controls and one restrained card treatment for overview and setup information. No decorative shadows in the browser table.

## Shapes

Cards use a 12-point continuous radius. File rows, tables, menus, sheets and buttons retain macOS native geometry.

## Components

`CardModifier`, `Banner`, `StatusPill`, `StatTile` and `Toast` in `Components.swift` are shared. The browser uses native `Table` selection and context menus. History buttons use the same clock symbol in the list, grid and history sheet.

## Do's and Don'ts

- Put the destination choice in the download action; retain a clearly named Downloads shortcut.
- Keep versions read-only until the user explicitly chooses a copy to download or open.
- Show loading and errors near the file browser instead of silently hiding history.
- Keep provider-specific help inside its preset. General app language says SFTP server.
- Verify light and dark mode, English/Croatian/German, keyboard selection and the minimum window size in the running app before release.

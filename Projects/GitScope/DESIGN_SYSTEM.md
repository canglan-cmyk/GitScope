# GitScope Design System

> Version 1.0 — August 2026

---

## 1. Design Principles

GitScope is a **professional developer tool** for macOS. The design language must communicate precision, clarity, and efficiency. Every pixel should serve a purpose.

| Principle | Description |
|-----------|-------------|
| **Clarity** | Information hierarchy is immediately obvious. Primary content dominates; secondary content recedes. |
| **Density** | Maximize useful information per screen area without feeling cramped. Developers prefer density over whitespace. |
| **Consistency** | Every component follows the same spacing, typography, and color rules. No ad-hoc values. |
| **Platform Native** | Respect macOS conventions (sidebar material, system colors, SF Pro/Mono). Feel like a first-party Apple tool. |
| **Accessibility** | Support system Dark/Light mode, respect contrast settings, maintain WCAG AA contrast ratios. |

---

## 2. Spacing System

GitScope uses a **4pt base unit** grid. All spacing values are multiples of 4.

### Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `space-2` | 2pt | Inline icon-to-text gap, tight badge padding |
| `space-4` | 4pt | Minimum gap between related elements |
| `space-6` | 6pt | Compact list item vertical padding |
| `space-8` | 8pt | Standard inner padding, control spacing |
| `space-12` | 12pt | Section padding, panel insets |
| `space-16` | 16pt | Major section gaps, panel-to-content margin |
| `space-20` | 20pt | Large section separators |
| `space-24` | 24pt | Panel header height padding |
| `space-32` | 32pt | Maximum spacing between major zones |

### Layout Zones

```
┌─────────────────────────────────────────────────────────────────────┐
│ Toolbar (44pt height)                                               │
├────────────┬──────────────────────────────────────┬─────────────────┤
│            │                                      │                 │
│  Sidebar   │         Diff Content Area            │  Right Panel    │
│  (240–     │         (flexible)                   │  (320pt fixed)  │
│   280pt)   │                                      │                 │
│            │                                      │                 │
├────────────┴──────────────────────────────────────┴─────────────────┤
│ Status Bar (22pt height)                                            │
└─────────────────────────────────────────────────────────────────────┘
```

| Zone | Width | Constraints |
|------|-------|-------------|
| Sidebar | 240–280pt | Min 200pt, max 360pt, resizable |
| Diff Content | Flexible | Fills remaining space |
| Right Panel (Search/Comments) | 320pt | Fixed when visible, overlay |
| Toolbar | Full width | 44pt height |
| Status Bar | Full width | 22pt height |

### Insets

| Context | Top | Leading | Trailing | Bottom |
|---------|-----|---------|----------|--------|
| Panel content | 12pt | 12pt | 12pt | 12pt |
| Sidebar controls stack | 12pt | 12pt | 12pt | 12pt |
| Diff line content | 0pt | 8pt (after gutter) | 8pt | 0pt |
| File header | 0pt | 12pt | 12pt | 0pt |
| Search result row | 4pt | 12pt | 8pt | 4pt |

---

## 3. Typography

GitScope uses **SF Pro** for UI text and **SF Mono** for code. All sizes follow the macOS HIG text style system.

### Type Scale

| Role | Font | Weight | Size | Line Height | Usage |
|------|------|--------|------|-------------|-------|
| **Panel Title** | SF Pro | Semibold | 13pt | 16pt | Panel headers ("搜索", "评论") |
| **Section Header** | SF Pro | Semibold | 12pt | 15pt | File group headers, category titles |
| **Body** | SF Pro | Regular | 13pt | 16pt | Primary content text, descriptions |
| **Secondary** | SF Pro | Regular | 11pt | 14pt | Paths, timestamps, metadata |
| **Caption** | SF Pro | Regular | 10pt | 13pt | Badges, counts, tertiary info |
| **Code** | SF Mono | Regular | 12pt | 18pt | Diff line content |
| **Code Small** | SF Mono | Regular | 11pt | 16pt | Search result previews, inline code |
| **Line Number** | SF Mono | Regular | 10pt | 18pt | Gutter line numbers |

### Typography Rules

1. **Maximum 3 font sizes** visible in any single panel at once
2. **Bold for emphasis only** — never for entire paragraphs
3. **Monospace exclusively for code** — never for UI labels
4. **Truncation**: use `.byTruncatingMiddle` for file paths, `.byTruncatingTail` for code previews
5. **Line height**: always use explicit line height; never rely on defaults

### Hierarchy Example (File Header)

```
┌─────────────────────────────────────────────────────────────────┐
│ ▼ NextAgent/Pages/Chat/ViewModel/NAChatViewModel.swift  +126 -17│
│   SF Pro Semibold 12pt              SF Mono Regular 10pt (green/red)
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Color System

### Semantic Colors

GitScope uses **system semantic colors** that automatically adapt to Light/Dark mode.

| Token | Light Mode | Dark Mode | Usage |
|-------|-----------|-----------|-------|
| `bg-primary` | `.windowBackgroundColor` | `.windowBackgroundColor` | Main content background |
| `bg-sidebar` | `.underPageBackgroundColor` | `.underPageBackgroundColor` | Sidebar, panels |
| `bg-elevated` | `.controlBackgroundColor` | `.controlBackgroundColor` | Popups, tooltips |
| `text-primary` | `.labelColor` | `.labelColor` | Primary text |
| `text-secondary` | `.secondaryLabelColor` | `.secondaryLabelColor` | Paths, metadata |
| `text-tertiary` | `.tertiaryLabelColor` | `.tertiaryLabelColor` | Placeholders, disabled |
| `separator` | `.separatorColor` | `.separatorColor` | Lines between sections |
| `accent` | `.controlAccentColor` | `.controlAccentColor` | Selected items, active states |

### Diff Colors

| Token | Light Mode | Dark Mode | Usage |
|-------|-----------|-----------|-------|
| `diff-add-bg` | `#E6FFEC` (green 6%) | `#0D2818` (green 8%) | Addition line background |
| `diff-add-text` | `#1A7F37` | `#3FB950` | Addition line number, + indicator |
| `diff-del-bg` | `#FFEBE9` (red 6%) | `#2D1215` (red 8%) | Deletion line background |
| `diff-del-text` | `#CF222E` | `#F85149` | Deletion line number, - indicator |
| `diff-add-highlight` | `#ABF2BC` (green 30%) | `#1B4721` (green 20%) | Inline character addition |
| `diff-del-highlight` | `#FECDCD` (red 30%) | `#5C1A1A` (red 20%) | Inline character deletion |
| `diff-hunk-bg` | `#DDF4FF` (blue 6%) | `#0D1D30` (blue 8%) | Hunk header background |
| `diff-hunk-text` | `#0969DA` | `#58A6FF` | Hunk header text (@@ ... @@) |

### Syntax Highlighting Palette

| Token | Light | Dark | Applies To |
|-------|-------|------|-----------|
| `syntax-keyword` | `#CF222E` | `#FF7B72` | if, let, func, class, import |
| `syntax-string` | `#0A3069` | `#A5D6FF` | String literals |
| `syntax-comment` | `#6E7781` | `#8B949E` | Comments |
| `syntax-number` | `#0550AE` | `#79C0FF` | Numeric literals |
| `syntax-type` | `#8250DF` | `#D2A8FF` | Type names, protocols |
| `syntax-function` | `#8250DF` | `#D2A8FF` | Function/method names |
| `syntax-property` | `#0550AE` | `#79C0FF` | Properties, variables |

### Status Colors

| Token | Color | Usage |
|-------|-------|-------|
| `status-added` | System Green | New file badge, + count |
| `status-deleted` | System Red | Deleted file badge, - count |
| `status-modified` | System Orange | Modified file badge |
| `status-renamed` | System Blue | Renamed file indicator |
| `status-reviewed` | System Green | "已看" checkmark |

---

## 5. Component Specifications

### 5.1 File Header Row

The file header is the most prominent repeating element in the diff view.

```
Height: 28pt
Background: diff-hunk-bg (light blue tint)
Left padding: 12pt
Right padding: 12pt

┌─[▼]─[Icon 14×14]─[4pt]─[File Name (Semibold 12pt)]─[flex]─[+N -M (Mono 10pt)]─[8pt]─[○ Review]─┐
│                                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

- Collapse triangle: 8×8pt, text-secondary color, 12pt from left edge
- File icon: 14×14pt, colored by extension (see icon mapping)
- File name: SF Pro Semibold 12pt, text-primary, truncate middle
- Stats: SF Mono Regular 10pt, green for +, red for -
- Review button: 16×16pt circle, 8pt from right edge
```

### 5.2 Diff Line Row

```
Height: 18pt (configurable via settings)
Background: white/diff-add-bg/diff-del-bg based on line type

┌─[Gutter 60pt]─[1pt separator]─[Content]─────────────────────────────────────────┐
│  old  new                      code text (SF Mono 12pt)                           │
│  123  124                                                                         │
└──────────────────────────────────────────────────────────────────────────────────┘

Gutter:
- Width: 60pt (30pt per column in unified, 60pt per side in split)
- Font: SF Mono Regular 10pt, text-tertiary
- Alignment: right-aligned with 4pt right padding
- Background: slightly darker than content (bg-sidebar)

Content:
- Left padding: 8pt after gutter separator
- Font: SF Mono Regular 12pt
- Line height: 18pt
- Tab width: 4 spaces
```

### 5.3 Sidebar File Tree Row

```
Height: 22pt
Indent per level: 12pt

┌─[Indent]─[Icon 14×14]─[4pt]─[File Name (Regular 12pt)]─[flex]─[+N -M (Caption 10pt)]─┐
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘

- Reviewed state: file name gets strikethrough + text-tertiary color
- Selected state: system highlight background, white text
- Hover state: subtle background highlight (controlBackgroundColor)
```

### 5.4 Search Panel

```
Width: 320pt (fixed overlay, right-aligned)
Background: NSVisualEffectView (sidebar material)
Left border: 1pt separator color

Header:
  ┌─[12pt]─["搜索" (Semibold 13pt)]─[flex]─[× Close (16pt)]─[8pt]─┐
  │                                                                   │
  │─[12pt]─[NSSearchField (full width - 24pt)]─[12pt]─               │
  │                                                                   │
  │─[12pt]─[Scope Buttons (Small)]─[8pt]─[Count (Caption 10pt)]─     │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘

Results:
  File row height: 36pt (name 12pt bold + path 10pt secondary)
  Match row height: 22pt (icon + code preview 12pt mono)
  Indent: file rows 8pt, match rows 24pt
```

### 5.5 Comments Panel

```
Width: 320pt (fixed overlay, right-aligned)
Background: NSVisualEffectView (sidebar material)

File group row: 36pt height
  - Name: SF Pro Semibold 12pt, truncate middle
  - Path: SF Pro Regular 10pt, text-secondary

Comment row: dynamic height (min 52pt)
  - Author: SF Pro Bold 11pt
  - Time: SF Pro Regular 10pt, text-secondary
  - Line: SF Mono Regular 10pt, text-tertiary
  - Body: SF Pro Regular 11pt, max 4 lines, wrapping
```

### 5.6 Buttons & Controls

| Control | Height | Font | Corner Radius |
|---------|--------|------|---------------|
| Segmented Control | 22pt | SF Pro Regular 11pt | System default |
| Push Button | 22pt | SF Pro Regular 12pt | 4pt |
| Icon Button | 20×20pt | — | 10pt (circle) |
| Search Field | 22pt | SF Pro Regular 12pt | 4pt |
| Popup Button | 22pt | SF Pro Regular 11pt | 4pt |
| Review Toggle | 16×16pt | — | 8pt (circle) |

---

## 6. Iconography

### File Type Icons

All file icons are **14×14pt** SF Symbols or system document icons with semantic coloring.

| Extension | Symbol | Color |
|-----------|--------|-------|
| `.swift` | `swift` | System Orange |
| `.h/.m/.c/.cpp` | `chevron.left.forwardslash.chevron.right` | System Blue |
| `.json` | `curlybraces` | System Yellow |
| `.plist/.xml/.yaml` | `gearshape.fill` | System Gray |
| `.md/.txt` | `doc.text` | System Gray |
| `.png/.jpg/.svg` | `photo` | System Cyan |
| `.js/.ts/.tsx` | `j.square.fill` | System Yellow |
| `.py` | `p.square.fill` | System Blue |
| `.css/.scss` | `paintbrush.fill` | System Pink |
| `.html` | `globe` | System Blue |
| `.sh/.bash` | `terminal.fill` | System Green |
| Other | `doc.fill` | Accent Color |

### Status Icons

| State | Symbol | Size | Color |
|-------|--------|------|-------|
| Reviewed | `checkmark.circle.fill` | 16pt | System Green |
| Unreviewed | `circle` | 16pt | text-tertiary |
| Collapsed | `chevron.right` | 8pt | text-secondary |
| Expanded | `chevron.down` | 8pt | text-secondary |
| Comment | `text.bubble` | 12pt | System Blue |
| Warning | `exclamationmark.triangle` | 12pt | System Yellow |

---

## 7. Motion & Transitions

| Action | Animation | Duration | Curve |
|--------|-----------|----------|-------|
| Panel show/hide | Slide from right + fade | 200ms | `.easeInOut` |
| File collapse/expand | Height animate | 150ms | `.easeOut` |
| Search highlight pulse | Opacity 0.5→1.0 | 300ms | `.easeInOut` |
| Row selection | Background color | 100ms | `.linear` |
| Tooltip appear | Fade in | 150ms | `.easeIn` |

### Rules

1. **No animation longer than 300ms** — developers value speed
2. **No bouncing or spring animations** — feels unprofessional in a code tool
3. **Respect "Reduce Motion"** — replace all animations with instant transitions when enabled
4. **Panel transitions are interruptible** — pressing ⌘F again during animation should reverse immediately

---

## 8. Dark Mode

GitScope **must** look excellent in both Light and Dark mode. Rules:

1. **Never use hardcoded colors** — always use semantic system colors or the tokens defined above
2. **Diff colors have separate Light/Dark values** — green/red backgrounds are darker in dark mode to avoid eye strain
3. **Syntax highlighting adapts** — lighter/brighter token colors in dark mode for contrast
4. **Borders and separators** — use `.separatorColor` which automatically adjusts opacity
5. **Images in diff preview** — add a subtle checkerboard background for transparent images in dark mode

---

## 9. Responsive Behavior

### Window Size Adaptations

| Window Width | Behavior |
|-------------|----------|
| < 800pt | Hide sidebar, show hamburger toggle |
| 800–1200pt | Sidebar visible, right panel overlays diff |
| > 1200pt | All three columns visible simultaneously |

### Minimum Window Size

- Width: 960pt
- Height: 620pt

### Panel Priorities (when space is constrained)

1. Diff content area (never smaller than 400pt wide)
2. Sidebar (can collapse to 0)
3. Right panel (always overlay, never steals diff space)

---

## 10. Accessibility

| Requirement | Implementation |
|-------------|----------------|
| Minimum contrast ratio | 4.5:1 for body text, 3:1 for large text |
| Focus indicators | 2pt blue ring on focused controls |
| VoiceOver | All interactive elements have accessibility labels |
| Keyboard navigation | Full Tab/Shift-Tab navigation through all controls |
| Zoom support | All text respects system text size (where applicable) |
| Color blindness | Never rely on color alone; always pair with icons/text |

---

## 11. Implementation Checklist

When building or modifying any GitScope UI component, verify:

- [ ] All spacing values are multiples of 4pt
- [ ] Font sizes match the type scale (no ad-hoc sizes)
- [ ] Colors use semantic tokens (no hex literals in code)
- [ ] Works in both Light and Dark mode
- [ ] Respects "Reduce Motion" preference
- [ ] Has VoiceOver accessibility labels
- [ ] Truncation behavior is specified (middle vs tail)
- [ ] Minimum touch/click target is 20×20pt
- [ ] Component looks correct at minimum window size (960×620)

---

## 12. Current Violations & Remediation

Based on the current codebase, these are the most impactful violations to fix:

| Issue | Current | Target | Priority |
|-------|---------|--------|----------|
| Search panel font sizes | Mixed 10–13pt | Unified per type scale | High |
| Diff line height | 18pt fixed | 18pt default, configurable | Medium |
| File header height | 28pt | 28pt (correct) | — |
| Sidebar insets | Mixed 8/12pt | Consistent 12pt | High |
| Comment cell spacing | Tight/overlapping | 6pt top, 4pt bottom | High |
| Color hardcoding | Some hex in code | All semantic tokens | Medium |
| Gutter width | Varies | Fixed 60pt | Medium |
| Panel width | 300–320pt mixed | 320pt standard | Low |
| Animation durations | None/inconsistent | Per motion spec | Low |

---

*This document should be stored at `Projects/GitScope/DESIGN_SYSTEM.md` in the repository and referenced by all contributors.*

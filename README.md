# cursdar2

`cursdar2` is the next-generation CUDA radar workstation being built on top of the fast Level 2 ingest and rendering work from `cursdar`.

The goal is an operator-grade desktop radar application with the same responsiveness as the current CUDA engine, but with a more deliberate workstation layout, cleaner browsing workflow, and room for deeper feature growth.

## What is implemented now

- Standalone source tree and build target inside `cursdar2/`
- Live AWS Level 2 ingest for the NEXRAD network
- Single-station 2D view and national mosaic rendering
- 3D volume rendering and draggable cross-sections
- Historic tornado case playback
- Archive snapshot loading for the March 30, 2025 all-site case
- NWS warning polygon overlays
- Storm-relative velocity controls
- Experimental TDS, hail, and mesocyclone markers
- Docked operator UI with:
  - station browser
  - station lock / auto-track toggle
  - inspector pane
  - warning list pane
  - historic timeline pane

## Current direction

`cursdar2` is no longer just a thin wrapper around the parent target. It now carries its own local copies of the app, CUDA renderer, ingest pipeline, UI, and support code so it can evolve independently.

The immediate focus is:

- tighten the workstation workflow
- expand tooling around archive review and warning analysis
- keep the fast CUDA rendering path intact while adding higher-level features

## Build

### Windows

```bat
build.bat
```

Output:

```text
build/cursdar2.exe
```

### Linux

```bash
chmod +x build.sh
./build.sh
```

## Controls

- `1-7`: select radar product
- `Left` / `Right`: cycle products
- `Up` / `Down`: cycle tilts
- `A`: toggle national mosaic
- `V`: toggle 3D volume
- `X`: toggle cross-section
- `S`: toggle storm-relative velocity
- `R`: refresh live data
- `Home`: reset to CONUS
- `Escape`: return to auto-tracking the nearest site
- `Space`: play/pause historic playback

## Notes

This is still an active build-out, not a finished operational workstation. The CUDA engine is already real; the remaining work is about expanding the surrounding workstation feature set and validating the full workflow under real weather use.

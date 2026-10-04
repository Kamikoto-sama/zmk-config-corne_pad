corne_pad_v2 zmk-config
![corne_pad_v2](https://github.com/user-attachments/assets/db98efdc-5b4c-499c-a9a8-687fbfbdb6a2)
keymap
![keymap](https://github.com/user-attachments/assets/41040f29-2bd2-4f8a-86ab-4e32b48a5660)

Cube studio
qq交流群：1037094476

## Local Docker build

Docker is the only local dependency. Build every target from `build.yaml` with:

```sh
./build-local.sh
```

This is an incremental build: the existing West workspace, downloaded modules,
and per-target build directories are reused. After editing a keymap or config,
run the same command again.

Build only selected targets with one or more target flags:

```sh
./build-local.sh --left
./build-local.sh --right
./build-local.sh --dongle
./build-local.sh --reset
./build-local.sh --left --right
```

Update ZMK and all modules explicitly with:

```sh
./build-local.sh --update
```

Force a clean rebuild when troubleshooting or after changing boards, shields,
or toolchain-related settings:

```sh
./build-local.sh --clean
```

The script keeps the West workspace and downloaded modules in the
`cornepad-zmk-workspace` Docker volume. Finished firmware is copied to
`firmware/`:

- `cornepad_left.uf2`
- `cornepad_right.uf2`
- `cornepad_dongle.uf2`
- `settings_reset.uf2`

Set `ZMK_IMAGE` or `ZMK_WORKSPACE_VOLUME` to override the Docker image or the
workspace volume name.

# MicBridge HAL Driver

First-party macOS `AudioServerPlugIn` virtual microphone driver.

Current status:
- Exposes one virtual input device: `MicBridge Virtual Mic`
- Exposes one virtual output stream on the same device for bridge injection
- Implements HAL object/property model for plugin/device/stream
- Implements IO callbacks with internal ring-buffer loopback (`WriteMix` -> `ReadInput`)

Build:

```bash
./drivers/micbridge-hal/scripts/build-driver.sh
```

Custom device name:

```bash
./drivers/micbridge-hal/scripts/build-driver.sh --device-name "Marco Virtual Mic"
```

Install (system-wide):

```bash
sudo ./drivers/micbridge-hal/scripts/install-driver.sh
```

Custom device name:

```bash
sudo ./drivers/micbridge-hal/scripts/install-driver.sh --device-name "Marco Virtual Mic"
```

Uninstall:

```bash
sudo ./drivers/micbridge-hal/scripts/uninstall-driver.sh
```

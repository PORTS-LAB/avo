# Device profiles

Templates for the "Profil device" dropdown in the Control Panel (spec §8).
Each file is `<id>.json`; the file name must match `id`.

```json
{
  "schema": 1,
  "id": "vendor-model",
  "name": "Vendor Model",
  "properties": {
    "ro.product.brand": "...",
    "ro.product.manufacturer": "...",
    "ro.product.model": "...",
    "ro.product.device": "...",
    "ro.build.fingerprint": "brand/product/device:release/id/incremental:type/tags"
  },
  "display": { "width": 1080, "height": 2400, "dpi": 420 }
}
```

Rules enforced by `DeviceProfile.validate()` (AvoKit) and CI:

- The five properties above are required (except for the default
  `avo-virtual-device`, which overrides nothing).
- Only identity properties (`ro.product.*`, `ro.build.fingerprint`,
  `ro.build.id`, …) may be set. Security state such as `ro.debuggable`,
  `ro.secure` or verified-boot properties is rejected.
- Brand names are used only so apps see a familiar device; they are not Avo
  branding. A profile does not pass hardware attestation, and the UI says so.

To add a device, copy an existing file, fill in values from the device's stock
`build.prop`, and open a pull request.

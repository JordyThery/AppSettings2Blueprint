# Third-party notices

AppSettings2Blueprint is MIT licensed (see LICENSE). It includes material
ported from the following project, which is distributed under its own licence.

## App Settings Utility

- Author: Anthony Darlow (CantScript)
- Repository: https://github.com/cantscript/AppSettingsUtility (reviewed at commit 5a4d7fa)
- Blog post: https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/

Identifier discovery in AppSettings2Blueprint is based on App Settings Utility.
The following parts were ported from `appSettingsUtility.sh` and reimplemented
in Swift. Every ported function starts with a comment naming its source function.

| Ported part | Source function | AppSettings2Blueprint |
| --- | --- | --- |
| Scan folders and the stop-at-.app walk | `scan_local_apps` | `Lookup/LocalAppScanner.swift` |
| Per-slice signing fields, SigningState requirement strings, the `*APPLE*` team placeholder, the composed `Bundle-ID {Designated-Requirement}` identifier, suggested PathPrefix | `inspect_local_app` | `Lookup/CodeSignatureInspector.swift` |
| App Store search endpoint and per-platform entities | `search_entity`, `platform_entity`, `platform_display_name` | `Lookup/AppStoreClient.swift` |
| Search result fields | `normalise_results` | `Lookup/AppStoreClient.swift` |
| Merging results by App Store ID with every platform label | `merge_results` | `Lookup/AppStoreClient.swift` |
| MDM lockup detail endpoint and offer selection | `load_app_details` | `Lookup/AppStoreClient.swift` |
| Storefront presets (GB, US, CA, AU, DE, FR) | `change_store` | `App/AppStoreModel.swift` |
| The embedded Apple app list (75 apps) and its 53-app built-in subset, with Apple's source URL and the 11 September 2026 verification date | `apple_preinstalled_data`, `apple_builtin_data` | `Resources/AppleBuiltInApps.json`, `Lookup/AppleBuiltInApps.swift` |
| BundleID-Lookup CSV columns and values (strings quoted, numbers bare, as jq `@csv` writes them) | `create_csv` | `Interop/CSVFormats.swift`, `Interop/CSVExporter.swift`, `Interop/CSVImporter.swift` |
| Local-Mac-Apps CSV columns, one row per architecture | `export_local_csv`, `inspect_local_app` | `Interop/CSVFormats.swift`, `Interop/CSVExporter.swift`, `Interop/CSVImporter.swift` |

### Licence

```
MIT License

Copyright (c) 2026 Anthony Darlow

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

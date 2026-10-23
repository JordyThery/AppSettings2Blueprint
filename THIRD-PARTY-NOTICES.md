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

The App Store endpoints, the embedded Apple app list and the CSV column layouts
will be listed here as they are ported.

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

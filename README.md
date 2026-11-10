# JellyReco's libmpv builds

The player engine (Libmpv.xcframework, from the `libmpv-build` branch) that JellyReco for iPhone
downloads while it builds. One folder per engine build (`libmpv-jr-<build number>/`), each with the
zip, its sha256 and the build record. `Vendor/MPVUI/Package.swift` on the app branch names the folder
and the zip's checksum, so a build only ever accepts that exact file.

Kept on this branch instead of the repo's Releases, which only list the apps.

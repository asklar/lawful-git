---
name: release
description: "Create a semver tag release and push it. Use when the user says /release. Expects a semver bump type: patch, minor, or major."
---

## Instructions

When the user invokes `/release`, create a new git tag following semantic versioning and push it to trigger the release workflow.

### Steps

1. **Determine the bump type.** The user should specify `patch`, `minor`, or `major`. If not provided, ask which one they want.

2. **Find the latest version tag.** Run:
   ```sh
   git tag --list 'v*' --sort=-v:refspec | head -n1
   ```
   If no tags exist, use `v0.0.0` as the base (so the first release will be `v0.0.1` for a patch bump).

3. **Compute the new version.** Parse the latest tag as `vMAJOR.MINOR.PATCH` and increment the appropriate component:
   - `patch`: increment PATCH, reset nothing
   - `minor`: increment MINOR, reset PATCH to 0
   - `major`: increment MAJOR, reset MINOR and PATCH to 0

4. **Confirm with the user.** Show: `Creating tag vX.Y.Z — proceed?`

5. **Create and push the tag.** Run:
   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

6. **Report success.** Tell the user the tag was pushed and that the release workflow will build and publish the binaries.

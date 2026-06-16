## Response Style
- No greetings, preambles, progress updates. Lead with the conclusion.
- Don't just agree with the user. Point out issues directly when necessary.

## Rules for Explaining Code
### When Addressing Feedback
- Explain the feedback and evaluate its validity. Then, describe the problem before the change, the modifications made, and the intent and content of the code after the change.

### When Modifying Code
- Explain what changes between the before and after versions, along with the intent and content of each.

### When Creating New Code
- Explain what changes between the state without code and the state with code (i.e., what problem it solves), along with the intent and content of the code.

## Implementation Standards
- Reference context7 and always implement according to the latest standard language specifications.

## Build
- Xcode builds into DerivedData, not the repo. After every build, copy the build product over `./MacColi.app` so `open MacColi.app` runs the latest binary.

## Project Structure
- The Xcode project uses synchronized folders (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77). New files added to `MacColi/` or `Tests/` on disk are picked up automatically — do NOT hand-edit `project.pbxproj` to register them.


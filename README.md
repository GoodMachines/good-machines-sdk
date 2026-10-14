# Good Machines SDKs

Client and server SDKs for Good Machines, a hosted service that adds an agent to your app.

- **Swift SDK** (`AgentKit`, `AgentChatUI`, `AgentFoundationModels`): adds a Good Machines agent to an iOS app. Needs iOS 27 or macOS 27 and Swift tools 6.4 or later.
- **`@gma/server`**: runs on your own server, so the agent can call your app's server as the signed-in user.

## Install

Swift: add this repository with Swift Package Manager at tag `0.2.3` (products AgentKit and AgentChatUI, plus AgentFoundationModels for Apple's on-device models).
Server: `npm install "git+https://github.com/GoodMachines/good-machines-sdk.git#server-sdk-v0.2.3"`.

Setup steps (keys, projects and the app's tools) come from the Good Machines MCP server, which invited developers connect to their coding agent; its `get_guide` and `get_setup` tools give the exact steps for your project.

## Access

Using these SDKs requires a Good Machines account and API key. Good Machines is in invite-only pilots and is not generally available.

The server side of Good Machines (the hosted API and MCP server) is not in this repository.

## License

Apache License 2.0. See [LICENSE](LICENSE).

# Windows Admin Center Extension

This extension installs Windows Admin Center. Windows Admin Center will run in
a Windows container on a Windows node.

# Configuration

|Name               |Required|Acceptable Value     |
|-------------------|--------|---------------------|
|name               |yes     |windows-admin-center |
|version            |yes     |v1                   |
|rootURL            |optional|                     |

# Example

``` javascript
    ...
    "agentPoolProfiles": [
      {
        "name": "windowspool1",
        "extensions": [
          {
            "name": "choco"
          }
        ]
      }
    ],
    ...
    "extensionProfiles": [
      {
        "name": "windows-admin-center",
        "version": "v1"
      }
    ]
    ...
```

# Supported Orchestrators

Kubernetes


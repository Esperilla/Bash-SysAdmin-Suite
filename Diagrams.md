# Project Diagrams

This file summarizes the general execution order of the project and of a typical Bash script in the lab.

## Flowchart
```mermaid
flowchart TD
    A[Start] --> B[Read config.txt]
    B --> C{Valid configuration?}
    C -- No --> D[Show error and exit]
    C -- Yes --> E[Choose script]
    E --> F[Read parameters and variables]
    F --> G[Execute main task]
    G --> H[Write to log]
    H --> I{Telegram configured?}
    I -- Yes --> J[Send notification]
    I -- No --> K[Skip notification]
    J --> L[End]
    K --> L[End]
```

### Flowchart sequence

1. The process starts when the user runs one of the project scripts.
2. The script finds and loads `config.txt` to obtain credentials, paths, and thresholds.
3. If the configuration does not exist or is invalid, the flow ends with an error.
4. If the configuration is valid, the script reads its own parameters and executes the main task.
5. After the task finishes, the result is recorded in the central log.
6. If Telegram is configured, the notification is sent; otherwise, evidence is left only in the log.
7. The flow ends.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Script as Bash Script
    participant Config as config.txt
    participant System as System Commands
    participant Log as Log
    participant Telegram as Telegram API

    User->>Script: Runs the script
    Script->>Config: Loads variables and parameters
    alt Invalid or missing configuration
        Script-->>User: Error and exit
    else Valid configuration
        Script->>System: Executes the main action
        System-->>Script: Returns the result
        Script->>Log: Records the operation
        alt Telegram configured
            Script->>Telegram: Sends notification
            Telegram-->>Script: OK response
        else Telegram not configured
            Script->>Log: Records skipped notification warning
        end
        Script-->>User: Final message
    end
```

### Sequence diagram order

1. The user launches the script from the terminal or from another automated flow.
2. The script checks `config.txt` before performing any important action.
3. If the configuration is missing, it returns an error and exits without continuing.
4. If the configuration exists, the script calls the system utilities required by its function.
5. Once it obtains the result, it stores it in the central log.
6. If Telegram data is available, it sends the notification to the bot.
7. Finally, it returns the status to the user and completes the execution.

## Flow scope

This scheme applies to the common behavior of the project scripts: `usuarios.sh`, `respaldo.sh`, `monitoreo.sh`, `servicios.sh`, `remoto.sh`, `red.sh`, and `inventario.sh`.

# Bridge Daemon

Swift control-plane daemon responsible for:
- selecting source/target devices from config
- running CoreAudio bridge engine
- recovering from sleep/wake and device reconnect events
- persisting health status for menu bar UX

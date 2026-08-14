# =============================================================================
# AZEROTHCORE - WORLD SERVER COMMAND REFERENCE
# =============================================================================

worldmenu        # Opens the main worldserver management menu
worldstart       # Starts the worldserver
worldstop        # Stops the worldserver safely
worldrestart     # Performs a safe worldserver restart
worldreload      # Sends "reload config" to the worldserver
worldkill        # Emergency-stops the worldserver
worldstatus      # Shows the current worldserver status

worldsave        # Manually saves the world
worldmonitor     # Opens the live worldserver console
worldlogs        # Shows the last 300 console lines
worldlogsfull    # Shows the full tmux scrollback

worldautostart   # Manages worldserver autostart
worldtimer       # Manages the daily restart timer

source-update    # Updates AzerothCore and modules
source-build     # Builds and installs the worldserver
worldcleanbuild  # Safely cleans the build directory

world-conf       # Opens worldserver.conf
world-values     # Opens values_world.conf
world-paths      # Opens world_paths.conf
world-update     # Applies the worldserver config patch

modules-conf     # Opens the module config editor
pb-conf          # Opens playerbots.conf
pb-values        # Opens values_playerbots.conf
pb-update        # Applies the Playerbots config patch

db               # Opens the Character DB MySQL console
db-list          # Shows and manages databases
account-delete   # Deletes accounts (single, range, or all)

worldcommands    # Shows all configured aliases
h                # Opens htop
glance           # Opens Glances system monitoring

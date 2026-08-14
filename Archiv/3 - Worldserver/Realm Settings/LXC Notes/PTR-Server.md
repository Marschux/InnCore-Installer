# LXC Notes - PTR-Server

## Proxmox Host
- Node-2
- LXC ID: 2099 - `wow-PTR-Server`
- Autostart: Nein

## IP
- vmbr0: 192.168.2.99 / 255.255.252.0
- vmbr_wow: 10.20.10.99 / 255.255.255.0

## Resources
- 12 Cores / 16 GB RAM / 2.0 GB Swap / 50 GB Disk

## Notes
- Azerothcore World Server, Debian
- Test für Azerothcore Plugins

## Proxmox Notes

HTML notes in the style of the Proxmox VE Helper-Scripts (centered box with
badges). Copy the block into the **Notes** field (guest → Summary → Notes →
edit). Proxmox renders the HTML, including the shields.io badge images.

### ------------------------------ insert text ------------------------------ ###
<div align='center'>
  <img src='https://github.com/azerothcore.png' width='80' style='border-radius: 8px; margin-top: 8px;' alt='AzerothCore Logo'/>
  <h2 style='font-size: 24px; margin: 16px 0;'>PTR-Server</h2>
  <p><b>Worldserver &middot; Realm ID 9 &middot; Test für Azerothcore Plugins</b></p>

  <p>
    <img src='https://img.shields.io/badge/IPv4-192.168.2.99-1f6feb?style=flat-square' alt='IPv4'/>
    <img src='https://img.shields.io/badge/vmbr__wow-10.20.10.99-1f6feb?style=flat-square' alt='vmbr_wow'/>
    <img src='https://img.shields.io/badge/OS-Debian_13-a80030?style=flat-square' alt='OS'/>
    <img src='https://img.shields.io/badge/Fail2Ban-enabled-3fb950?style=flat-square' alt='Fail2Ban'/>
    <img src='https://img.shields.io/badge/MOTD-enabled-3fb950?style=flat-square' alt='MOTD'/>
  </p>

  <p style='margin-top: 4px;'>
    <span style='margin: 0 10px;'><a href='https://www.azerothcore.org/' target='_blank' rel='noopener noreferrer'>Website</a></span>
    <span style='margin: 0 10px;'><a href='https://github.com/mod-playerbots/azerothcore-wotlk' target='_blank' rel='noopener noreferrer'>GitHub</a></span>
  </p>
</div>
### -------------------------------- end text ------------------------------- ###

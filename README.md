# bcc-stables

## Description

Embark on an adventure through the untamed wilderness of the Old West with bcc-stables! Here, your trusty steed awaits, ready to be personalized with unique mane styles, tail variations, coat colors, and stylish accessories. Groom, feed, and clean your horse to keep them at peak performance.

## Features

- **Horse Management**: Buy and sell horses through the stables using cash and/or gold.
- **Ownership Limits**: Maximum owned horses can be set separately for players and trainers in the config.
- **Inventory Management**: Individual inventory size for each horse model.
- **Customization**: Choose horse gender at purchase and use oil lanterns from inventory to equip a lantern to your horse.
- **Shop Hours**: Set individually for each stable or disable to keep the stable open.
- **Blips**: Colored and changeable per stable location, reflecting if the stable is open, closed, or job-locked.
- **Access Control**: Stable access can be limited by job and job grade.
- **Horse Return**: Return horse at stable (when open) or using the flee button in the horse menu.
- **Care and Maintenance**: Feed and water your horse to increase health and stamina. Brushing your horse will clean it and give a slight increase in health and stamina.
- **Data Persistence**: Horse Health and Stamina core values are saved in the database.
- **Cooldown**: Configurable cooldown time for selling tamed horses.
- **NPC Spawns**: Distance-based NPC spawns.
- **Training System**: Horse Training System and Horse Trading between players.
- **Config Options**: Only trainers can buy horses from a stable (set per stable).
- **Revival**: Revive your downed horse using the horse reviver item.
- **Looting**: Allow player horse looting.
- **Death Management**: Horse death management set in the main config file.

## Horse Training

### XP System

Gain XP by riding, feeding, watering, and brushing your horse. As XP is gained, bonding levels will increase (0-4) for better horse stats and tricks.

### Bonding Levels

- **Level 1**: Horse can drink from rivers and lakes.
- **Level 2**:
  - Horse can rest. *(Future update will regain stamina)*
  - Shocking events disabled for a calmer horse.
  - Trick: **Rear-Up** by pressing `left-ctrl` + `space`
- **Level 3**:
  - Horse can sleep. *(Future update will regain health and stamina)*
  - Gunshot flee response disabled.
  - Trick: **Skid/Slide** by pressing `left-ctrl`
- **Level 4**:
  - Horse can wallow.
  - Trick: **Dance** by pressing `space`
  - Trick: **Side-Pass** by pressing `space` + `A` or `D`

## Horse Taming

- Tame wild horses and return to a trainer area to sell or register your tamed horse.
  - If you want to keep the tame and have room in your stable, pay a registration fee, and it will be added to your stable.
- Job check if Trainer job is required.
- If the player does not have the Trainer job, the tamed horse can be given to a trainer to sell or register.

## Horse Trading

- While leading your horse, approach another player, and a trade prompt will appear.

## Tips

- **Whistling**: A short whistle will call your horse. A long one will set your horse to follow you. A second whistle or mounting your horse will cancel following.
- **Horse Info**: Press `Q` in the horse prompts to view standard horse info.

## Commands

- `/horseRespawn`: Respawn your horse while bypassing the distance check.
- `/horseInfo`: View more detailed horse info than the standard **Show Info** display.
- `/horseSetWild`: *Dev Mode Only* - Set a tamed horse wild to test taming.
- `/horseWrithe`: *Dev Mode Only* - Set horse to writhe state to test reviving.

## Dependencies

This version runs on the Feather Framework. See [FEATHER_PORT.md](FEATHER_PORT.md)
for what moved to which Feather resource.

- feather-mysql
- feather-core
- feather-character
- feather-notify
- feather-menu-v2
- feather-assets (horse ownership)
- feather-economy (cash and gold)
- feather-inventory (saddlebags and horse items)
- feather-jobs (trainer and job-locked stables)

## Installation

1. Make sure the dependencies are installed and start before this script.
2. Apply `sql/install_items.sql` to the database once (adds the horse items to
   feather-inventory; safe to run again).
3. Copy any image from `img/` that feather-inventory does not have yet into
   `feather-inventory/ui/images/items/`.
4. Add `ensure bcc-stables` to `server.cfg` after the Feather domain resources
   and `feather-admin`.
5. Restart the server and run `StablesReleaseSmokeTest` in the server console.

The stable creates its own tables on first start. It never stores horse owners
or balances; those live in feather-assets and feather-economy.

## Credits

- lrp_stables
- [ByteSizd](https://github.com/AndrewR3K) - Vue Boilerplate for RedM
- [SavSin](https://github.com/DavFount) - UI conversion to VueJS
- Stephenlikewhoa
- [Dokoboe](https://github.com/dokoboe)

## GitHub

- [bcc-stables](https://github.com/BryceCanyonCounty/bcc-stables)

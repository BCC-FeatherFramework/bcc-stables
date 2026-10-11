# BCC Stables Feather port

**Base:** upstream bcc-stables 1.7.5 (BryceCanyonCounty release 1.7.4 package, built UI included)
**Version:** 2.0.0
**Status:** Running on the development server. `StablesReleaseSmokeTest` 7/7 and the
purchase, tack and saddlebag flows passed on 2026-10-03; the other flows are still untested.

The stable keeps its menus, NUI, prompts, horse behaviour, config files and
translations. What changed is who owns the data: horses belong to
feather-assets, money to feather-economy, saddlebag items to feather-inventory,
and jobs to feather-jobs. There is no VORP, bcc-utils or oxmysql code left.

This port is the first consumer of feather-assets (phase A3 of the Assets
master plan).

## Who owns what

| Data | Before (VORP) | Now |
|---|---|---|
| Horse identity, model, owner | `player_horses.id`, `model`, `charid` | feather-assets asset (`assetType = 'horse'`) and its owner interest |
| Name, gender, tack components | `name`, `gender`, `components` | Assets metadata, version 1: `{ name, gender, components }` |
| Permanent death, sale | row flag `dead`, `DELETE` | `RetireAsset` (`stables.horse_died`, `stables.horse_sold`) |
| Trade to another player | `UPDATE charid` | `TransferOwnership` with the seller asserted |
| XP, health, stamina, writhe, captured | `player_horses` columns | `bcc_stables_horses`, keyed by asset UUID |
| Selected horse | `player_horses.selected` | `bcc_stables_selection` (per character) |
| Purchases, tack, registration fee | `character.removeCurrency` | Economy `Transfer` wallet to system sink |
| Sale payouts | `character.addCurrency` | Economy `Issue` (see **Sales** below) |
| Saddlebags | `vorp_inventory` custom inventory `horse_<id>` | feather-inventory custom inventory per asset |
| Usable items, durability | `vorp_inventory` usable items, metadata | feather-inventory usable items, item condition |
| Trainer and job checks | `character.job`, `jobGrade` | feather-jobs `CheckAssignment` |
| Notifications, callbacks | `vorp_core` | feather-notify, feather-core RPC |

Horse IDs sent to the client and NUI are now the asset UUIDs. The UI only passes
them through, so the prebuilt UI is unchanged.

## Workflows

Every money-moving action is a durable order in `bcc_stables_orders`:

```text
pending  -> Economy charge or payout (idempotency key bcc-stables:order:<orderId>)
paid     -> Assets step (register / save tack / retire)
fulfilled
```

| Order | Money step | Assets step |
|---|---|---|
| `purchase` | Charge horse price (cash or gold) | `RegisterAsset`, provenance `stable_purchase` |
| `tame_register` | Charge `Config.regCost` | `RegisterAsset`, provenance `tamed_capture` |
| `tack` | Charge the price of new pieces only | `UpdateAssetMetadata` (components) |
| `sale` | Payout sell price | `RetireAsset` (`stables.horse_sold`) |
| `tamed_sale` | Payout tamed price | none |

- A confirmed refusal (insufficient funds, permission denied) rejects the order;
  nothing else happens.
- An unknown outcome leaves the order where it is. It is retried with the same
  idempotency key the next time the character opens the stable, so money never
  moves twice and a paid horse is never lost.
- A step that can never succeed after money moved (for example, the horse was
  traded away meanwhile) marks the order `review` and logs `event=order.review`
  for staff.
- One order runs at a time per character, and never while an older one is open.
- Each Assets change made by an order carries `referenceType = 'stables_order'`
  and the order UUID, so an asset event links to its Economy transaction.

### Reconciliation (server console)

| Command | Purpose |
|---|---|
| `StablesOrdersReport [all]` | Lists unresolved orders (`pending`, `paid`, `review`) with age and last error; `all` adds recent closed ones. |
| `StablesOrdersRetry <orderId>` | Runs an unresolved order again with its original idempotency keys. A `review` order resumes at its Assets step (its money already moved). Works while the player is offline. |
| `StablesOrdersResolve <orderId> <fulfilled\|rejected> <note>` | Closes an order by hand after staff settled it elsewhere. Records the note and time; moves no money and changes no horse. |

For a `paid` or `review` order the report shows the Economy transaction, so staff
can refund or settle it before resolving it as `rejected`.

## Server checks added

The VORP version trusted several client values. The port recomputes them:

- **Prices** come from config. Tack is priced per new component from
  `HorseComp`; the client's price total is ignored.
- **Stable and trainer actions** require the player to stand at that stable or
  trainer.
- **Job-locked horses and stables** are checked on purchase, not only in the menu.
- **Ownership** is checked with Assets for every per-horse action (select, XP,
  stats, rename, tack, sale, trade, saddlebags).
- **Trades** require the other player within `Config.feather.tradeDistance`.
- **Saddlebags** require the horse entity next to the player; looting another
  player's horse also needs `Config.shareInventory` and that horse's asset ID.
- **Item use** is confirmed by the client before food is consumed or a tool wears,
  and only for the instance the player actually used.
- A horse with items in its saddlebags cannot be sold.
- Equipped weapons cannot be put in saddlebags: feather-weapons refuses the move and
  feather-inventory shows "Unequip this item before moving or removing it.".

## Sales need an Economy decision

Selling a horse (stable or trainer) pays the player with Economy `Issue`. Economy
only allows trusted suppliers to create currency, and bcc-stables is **not**
granted that. Until the team decides, sales fail safely: the order is rejected,
the horse is kept, and the player sees "The stable can't buy horses right now".
This matches the bcc-shops position on NPC payouts.

To enable sales, the team chooses one of:

1. Add `bcc-stables` to Economy `trustedSuppliers` and grant
   `economy.currency.issue` to it in the feather-admin service policy.
2. Add a per-resource, per-reason allow-list in Economy (like `BankSupply`) for
   `stables.horse_sale` and `stables.tamed_sale`.

## Trust and policy grants (already applied)

| Resource | Setting | Grant |
|---|---|---|
| feather-assets | `Config.Access` | `trustedReaders`, `trustedManagers`, `trustedAuditors` |
| feather-admin | `Config.servicePolicy['feather-assets']` | `assets.asset.manage`, `assets.ownership.transfer` |
| feather-economy | `Config.Access` | `trustedReaders`, `trustedProvisioners`, `trustedTransactors` (not suppliers) |
| feather-jobs | `Config.Access` | `trustedReaders` |

Restart feather-assets, feather-economy, feather-jobs and feather-admin after
deploying so they load these lists.

## Behaviour changes from upstream

| Topic | Change |
|---|---|
| Discord webhooks | Removed. Ownership changes are audited by feather-assets; orders are in `bcc_stables_orders`. |
| Saddlebag size | Each color's `invLimit` is now the saddlebag weight limit in pounds. Slots: `Config.feather.saddlebags.maxSlots`. |
| Saddlebag options | VORP-only options (weapon whitelists, per-item limits, job permissions) removed. `Config.itemsBlackList` remains. |
| Flaming hooves durability | Off by default: `diamond` is a stackable item and condition needs a unique item. |
| Horse names | Trimmed, 1 to `Config.feather.nameMaxLength` characters, no `<` or `>`. |
| Job-locked horses | A character with several jobs sees every horse any of them unlocks. |
| Character switch | The spawned horse is removed on `Feather:Character:Logout`. |
| Routing | The horse entity is re-resolved when feather-routing returns the player to the shared world (`routing.player.left.v1`). |

## Tables

| Table | Purpose |
|---|---|
| `bcc_stables_horses` | Gameplay state per asset. Rows are never deleted (the saddlebag foreign key cascades). |
| `bcc_stables_selection` | Selected horse per character |
| `bcc_stables_orders` | Order receipts, states and manual resolutions |
| `bcc_stables_schema_migrations` | Checksummed migration ledger |

There is no legacy import: this server never had a `player_horses` table. A
server migrating from VORP would need a one-off import that maps `charid` to
character UUIDs and registers each row with provenance `legacy_player_horses`.

## Files

| Path | Purpose |
|---|---|
| `server/feather/init.lua` | Characters, RPC, notifications, domain call wrapper |
| `server/feather/assets.lua` | feather-assets boundary |
| `server/feather/economy.lua` | feather-economy boundary |
| `server/feather/inventory.lua` | feather-inventory boundary |
| `server/feather/jobs.lua` | feather-jobs boundary |
| `server/services/migrations.lua` | Schema |
| `server/services/horses.lua` | Gameplay state and client horse shape |
| `server/services/orders.lua` | Order workflows |
| `server/main.lua` | RPC handlers and startup |
| `server/items.lua` | Usable items |
| `server/commands.lua` | Order reconciliation console commands |
| `server/chat_suggestions.lua` | feather-chat suggestions for `/horseRespawn` and `/horseInfo` |
| `server/tests.lua` | `StablesReleaseSmokeTest` |
| `client/feather/init.lua` | Client RPC and notifications |
| `client/menus/horse_info.lua` | Horse info panel on feather-menu-v2 |
| `sql/install_items.sql` | Item definitions for feather-inventory |

## Validation

Done (2026-10-03):

- lua-language-server: no errors beyond CfxLua backtick hashes, which RedM
  accepts.
- `StablesReleaseSmokeTest` 7/7.
- In game: cash purchase ($140, priced from config), tack ($30 for three new
  pieces, priced on the server), saddlebags opened (container linked to the asset).

Still to test on the server:

1. In game:
   - buy a horse with gold;
   - rename it;
   - call and return it, feed, brush and use the lantern;
   - trade it to a second player;
   - tame and register a wild horse;
   - try a sale (expect "can't buy horses" until the Economy decision).
2. Restart bcc-stables in the middle of a purchase and confirm the order finishes
   on the next stable visit, or with `StablesOrdersRetry`.

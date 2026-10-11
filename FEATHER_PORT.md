# BCC Housing: Feather port

**Status:** in progress (started 2026-10-11). Not started in `server.cfg` until the port is complete.
**Version:** 3.0.0 (from upstream bcc-housing 2.5.0)
**Plans:** phase B2 of the [BCC on Feather master plan](https://github.com/BCC-FeatherFramework/bcc-feather-masterplan);
phase P3 (first consumer) of the [Feather Property master plan](https://github.com/FeatherFramework/feather-framework-docs/blob/main/feather-property/Feather_Property_Master_Plan.md).
**Domain mapping and decisions:** [feather-property PROPERTY_PLAN.md](https://github.com/BCC-FeatherFramework/feather-property/blob/main/PROPERTY_PLAN.md) §3 and §6.

The houses, hotels, furniture, PolyZones, interiors, menus, NPC agents and
translations stay. Ownership, money, storage and access move to the Feather
domains that own them; bcc-housing keeps no money and no ownership truth.

## Phases

| Phase | Scope | State |
|---|---|---|
| H1 Foundation | Feather adapters (DBG, RPC, notifications, characters, webhook), feather-toolkit prompts/blips/peds/objects/keys, feather-menu-v2 wrapper, Core locales, Feather character events, manifest on Feather only, PolyZone optional | code complete |
| H2 Staff and jobs | Authority capability `staff.housing.manage` + Feather Admin staff capability; agent/realtor jobs through feather-jobs `CheckAssignment` | |
| H3 Property | Configured houses and hotels registered in feather-property (`bcc-housing:<uniqueName>`, `bcc-housing:hotel:<hotelId>`); custom houses on creation; owners/co-owners/tenants as interests; UUID schema; `property_id` link column | |
| H4 Money | Purchase, rent, taxes and rent with a paid-until date (no ledger), sale to player and to the NPC agent, furniture purchase and sell-back, storage upgrades: all through feather-economy | |
| H5 Storage and deeds | House and hotel storage as feather-inventory containers; deed as an inventory item with `propertyId` metadata | |
| H6 Doors, access, instances | Doors through the bcc-doorlocks server API (no direct table writes); guest list kept locally until feather-access; instances through feather-routing (server-chosen) | |
| H7 Tests and docs | `HousingReleaseSmokeTest`, DevMode live test, README, trust entries, console commands | |

## Rules (from the master plan)

- No `vorp_*`, `bcc-utils`, `oxmysql`, `feather-menu` (v1), `feather-roles`.
- bcc-housing never writes another resource's tables (today it writes `doorlocks`).
- No money held in bcc-housing tables (today: `ledger`, `bcchousing_transactions`).
- `Config.DevMode = false` in the committed config.

## Notes

- **PolyZone** is not a Feather resource and is not installed on the development
  server. It is optional now: house areas use the built-in polygon check (X/Y plus the
  configured floor and ceiling), and PolyZone only draws outlines when it runs.
- Translations are registered in feather-core as `bcc-housing.<key>` for `en_us`, `ro`,
  `pl`, `de`, `fr` and `uk`; each player sees their own language.
- Character objects come from Core sessions (`HousingCharacters.Get`); `HousingUser(src)`
  keeps the old `user.getUsedCharacter` call shape until the money phase rewrites the
  call sites that read balances.

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
| H2 Staff and jobs | Authority capability `staff.housing.manage` (role `staff.housing.admin`, `HousingAdminGrant`/`HousingAdminRevoke`) + Feather Admin staff capability; realtor (`Config.Admin.jobs`) and agent shop jobs through feather-jobs `CheckAssignment` | code complete |
| H3 Property | Configured houses and hotels registered in feather-property on start (`bcc-housing:<uniqueName>`, `bcc-housing:hotel:<hotelId>`); staff-created houses on creation (`bcc-housing:custom:<houseid>`); purchase/rent, sale to player and agent, unrent, staff delete and hotel rooms go through Property interests (one holder per house: owner or tenant); `IsHouseOwner` and hotel checks ask Property; `property_id` link; start-up reconciliation; `HousingPropertyStatus <houseid>` | code complete |
| H4 Money | All money through feather-economy, none kept here: purchase/rent deposit (paid after the house is reserved; undone on failure), hotel rooms, furniture buy and agent buy-back, storage upgrades (stage claimed first), taxes and rent from the wallet on each due date with a `taxes_paid_until` date for months paid ahead (ledger removed; empty wallet = overdue + Property suspended), sale to the agent paid at once through Issue (`bcchousing_transactions` is only a retry queue with idempotency keys), sale between players only after the buyer accepts an offer (Property transfer, then buyer-to-seller payment, transfer undone if payment fails); Rol tokens refused | code complete |
| H5 Storage and deeds | House storage: one feather-inventory container per house row (foreign key `bcchousing.houseid`, deleted with the row); hotel storage: one container per character and hotel (`bcchousing_hotel_rooms`); opened through a temporary access grant after the owner/roommate check; slots capped by `Config.Setup.MaxStorageSlots`. Deeds and the furniture book are feather-inventory items (`sql/install_items.sql`); a deed's metadata carries the house and feather-property IDs | code complete |
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

## Trust entries needed

| Resource | Entries for `bcc-housing` | Phase |
|---|---|---|
| feather-authority `config.lua` | `trustedReaders`, `trustedCapabilityRegistrars`, `trustedRoleCreators`, `trustedGrantors`, `trustedAssigners` | H2 (added on the dev server) |
| feather-jobs `config.lua` | `trustedReaders` | H2 (added on the dev server) |
| feather-property `config.lua`; feather-admin `configs/service_policy.lua` | `trustedReaders`, `trustedManagers`, `trustedAuditors`; `['feather-property']['bcc-housing']` `property.property.manage`, `property.interest.manage` | H3 (added on the dev server) |
| feather-economy `config.lua`; feather-admin `configs/service_policy.lua` | `trustedReaders`, `trustedProvisioners`, `trustedTransactors`, `trustedSuppliers`; `['feather-economy']['bcc-housing']['economy.currency.issue']` (agent buy-back, furniture sell-back) | H4 (added on the dev server) |
- **Holder cache:** `bcchousing.charidentifier` and `bcchousinghotels` only cache the
  holder; feather-property is the truth. On start every configured house and hotel is
  registered and each house row is reconciled (a different holder fixes the cache; a row
  without a holder is reported, not deleted).
- **Roommates** (`allowed_ids`, up to `playerMax`) get door and house access but cannot
  sell or manage the house. They are delegated access, not ownership, so they stay in
  bcc-housing until feather-access exists (the Access master plan defers it).
- **No VORP data migration:** the development database has no bcc-housing tables; VORP
  numeric character IDs could not be mapped to Feather characters anyway.
- **Fixed in H4:** a sale to another player used to take the buyer's money without
  asking them. The buyer now gets an offer (60 seconds) and pays only by accepting.

# BCC Housing: Feather port

**Status:** code complete (H1–H7, 2026-10-12). Started on the development server: `HousingReleaseSmokeTest` 13/13 (33 houses and 7 hotels registered in feather-property). Next: live acceptance below.
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
| H6 Doors, access, instances | Doors only through the bcc-doorlocks server API (`AddDoor` returns IDs, `GetDoorByInfo`, client sync): configured doors locked for the holder on purchase, deleted on sale to the agent/unrent/sale without inventory, re-keyed to the buyer on sale with inventory; owners and staff add a door by picking it (`pickDoor`) and the server checks holder/staff and distance (the old route accepted any door ID from the client); roommate add/remove updates the locks. Interiors (hotel rooms, teleport houses) enter through `bcc-housing:EnterInstance`: the server checks access and joins a feather-routing route (private per character and hotel, shared per house); the client never picks a bucket | code complete |
| H8 Contracts | Monthly tax and rent are feather-contracts obligations (Contracts phase C4, first real issuer): types `housing_property_tax` and `housing_rent` (system issuer and creditor, no acceptance, issuer may collect, debtor may pay, no disputes) registered on start; on a due date bcc-housing drafts, issues and collects the obligation with request IDs fixed per house, due date and holder; insufficient funds = overdue (obligation stays open); arrears settle that obligation with the holder as actor; an unknown Economy outcome stays pending in Contracts and the next hourly run picks up the result; `bcchousing.tax_obligation_id`; staff delete cancels the open obligation. Paying ahead stays a direct Economy payment | code complete; 2026-10-13: `HousingTaxCollectAt 2026-11-12 1` charged 600 dollars through a settled Contracts obligation, verified by `ContractsReconcile`; overdue/arrears and rent still to run |
| H7 Tests and docs | `HousingReleaseSmokeTest` (13 read-only checks; 14 with the H8 Contracts check), README rewritten for Feather (requirements, trust entries, service policy, commands, configuration), `sql/install_items.sql` | code complete; live acceptance to run |

## Rules (from the master plan)

- No `vorp_*`, `bcc-utils`, `oxmysql`, `feather-menu` (v1), `feather-roles`.
- No VORP naming: `characterId` / `character_id`, never `charIdentifier` / `charidentifier`.
- bcc-housing never writes another resource's tables (doors go through the bcc-doorlocks API since H6).
- No money held in bcc-housing tables (today: `ledger`, `bcchousing_transactions`).
- `Config.DevMode = false` in the committed config.

## Notes

- **PolyZone** is not a Feather resource and is not installed on the development
  server. It is optional now: house areas use the built-in polygon check (X/Y plus the
  configured floor and ceiling), and PolyZone only draws outlines when it runs.
- Translations are registered in feather-core as `bcc-housing.<key>` for `en_us`, `ro`,
  `pl`, `de`, `fr` and `uk`; each player sees their own language.
- Character objects come from Core sessions (`GetHousingCharacter(src)`, a
  `{ source, characterId, accountId, firstname, lastname }` table). Since 2026-10-13
  the VORP names are gone: `characterId` in Lua, `character_id` (`CHAR(36)`) in every
  bcc-housing table; older tables are renamed on start (`charidentifier`, and
  `identifier` on the payout queue).

## Trust entries needed

| Resource | Entries for `bcc-housing` | Phase |
|---|---|---|
| feather-authority `config.lua` | `trustedReaders`, `trustedCapabilityRegistrars`, `trustedRoleCreators`, `trustedGrantors`, `trustedAssigners` | H2 (added on the dev server) |
| feather-jobs `config.lua` | `trustedReaders` | H2 (added on the dev server) |
| feather-property `config.lua`; feather-admin `configs/service_policy.lua` | `trustedReaders`, `trustedManagers`, `trustedAuditors`; `['feather-property']['bcc-housing']` `property.property.manage`, `property.interest.manage` | H3 (added on the dev server) |
| feather-economy `config.lua`; feather-admin `configs/service_policy.lua` | `trustedReaders`, `trustedProvisioners`, `trustedTransactors`; `Config.IssueReasons` `housing.sold_to_agent`, `housing.furniture_sold` (not a trusted supplier since 2026-10-16); `['feather-economy']['bcc-housing']['economy.currency.issue']` (agent buy-back, furniture sell-back) | H4 (added on the dev server) |
| feather-contracts `config.lua`; feather-admin `configs/service_policy.lua` | `trustedIssuers`; `['feather-contracts']['bcc-housing']` `contracts.obligation.issue`, `.cancel`, `.default` | H8 (added on the dev server) |
- **Holder cache:** `bcchousing.character_id` and `bcchousinghotels` only cache the
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
- **Fixed 2026-10-13:** a house suspended for overdue taxes could still be sold to the
  agent (Property allows `EndInterest` while suspended), and two sale requests close
  together could both be paid. Sale to the agent and unrent now release only an active
  property held by the caller (checked on the same snapshot as the release), and the
  payout goes only to the request that deletes the house row.

## Live acceptance (to run)

Offline first (DevMode, nobody online): `HousingPropertyFlowTest <characterUuid> <otherCharacterUuid>`
runs steps 2, 6 and 7 on feather-property through the same flows as the menus
(`HousingFlows` in `buyHouse.lua`, `sellHouse.lua`, `hotels.lua`): rent, a non-tenant cannot
end the rental, unrent, buy (deed stored), sale with inventory to the second character, the
former owner cannot sell, sale to the agent (payout paid), hotel room (not twice; ended again
as cleanup). Both characters must hold no house. In game, the offer on the buyer's screen,
menus, blips and door prompts still need a player. Passed 15/15 on 2026-10-13 (house16).

1. `HousingReleaseSmokeTest`: every line PASS.
2. Buy a configured house; a second player cannot buy it. Rent another; unrent it.
3. Pay taxes ahead. With `Config.DevMode = true`, `HousingTaxCollectAt <YYYY-MM-DD> <houseid>`
   runs the monthly charge for one house as of that date with nobody online (it works even
   with `collectTaxes = false`). `HousingArrearsFlowTest <houseid> <YYYY-MM-DD> <otherCharacterUuid>`
   runs the whole overdue path offline (parks the holder's money with the other character,
   charge, overdue and suspended, payment refused, staff release, money returned, arrears
   paid, same obligation settled, house active). `HousingTaxRelease <houseid>` and
   `HousingTaxPayAs <characterUuid> <houseid> <months>` run single steps. Offline, the
   arrears are collected by bcc-housing; paying them in game runs with the player as debtor.
   `HousingArrearsFlowTest 1 2026-12-12 <emma>` passed 10/10 on 2026-10-13; `ContractsReconcile`
   stayed HEALTHY.
   Each charge must show in Contracts as a settled `housing_property_tax` (or `housing_rent`)
   obligation; an overdue house keeps one open obligation, which the arrears payment settles.
   `ContractsReconcile` stays HEALTHY with the settlements verified against Economy.
4. Storage: put items in, restart, items still there; buy an upgrade stage.
5. Doors: purchase locks the configured doors for you; add a door with "Create new door";
   add and remove a roommate (door access follows).
6. Sell to the agent (money arrives); sell to another player (they must accept; decline once).
7. Hotel: buy a room, enter (private instance), storage, leave.
8. Furniture: buy, place, move, sell back; furniture book.
9. Deed: issued on purchase, moves to the buyer on a sale.
10. Staff: create a house for another character with picked doors; delete it.

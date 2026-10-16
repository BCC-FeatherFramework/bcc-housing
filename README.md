# bcc-housing

> Houses, rentals, hotels, furniture and property taxes for RedM on the **Feather Framework**.

Version **3.0.0** is the Feather port of BryceCanyonCounty's bcc-housing 2.5.0. Houses, hotels, furniture, PolyZones, interiors, menus, NPC agents and translations are unchanged; ownership, money, storage, doors and interiors go through the Feather domains that own them. bcc-housing keeps no money and is not the source of truth for who owns a house. Port details and phases: [FEATHER_PORT.md](FEATHER_PORT.md).

## How it uses Feather

| Concern | Owner |
|---|---|
| Who owns or rents a house; hotel rooms | **feather-property** (`bcc-housing:<uniqueName>`, `bcc-housing:custom:<id>`, `bcc-housing:hotel:<id>`) |
| Prices, rent, taxes, furniture, sales | **feather-economy** (wallets; no ledger, no balances here) |
| Monthly tax and rent debts | **feather-contracts** (obligation types `housing_property_tax`, `housing_rent`) |
| House and hotel storage, deeds, furniture book | **feather-inventory** |
| Door locks | **bcc-doorlocks** server API |
| Interiors (hotel rooms, teleport houses) | **feather-routing** |
| Housing staff | **feather-authority** (`staff.housing.manage`) and Feather Admin staff |
| Realtor and agent jobs | **feather-jobs** |
| Characters, RPC, translations, notifications | feather-core, feather-character, feather-notify |
| Menus, prompts, blips, NPCs | feather-menu-v2, feather-toolkit |

## Features

- **Houses for sale or rent** from `configs/houses.lua`, priced in dollars or gold. Two buyers can never get the same house.
- **Staff-created houses** for any character (`/HousingManager`), with radius or PolyZone areas and picked doors.
- **Roommates** (up to `playerMax`) get door and house access; only the holder can sell or manage.
- **Taxes and rent** are charged every month on the day the house was bought. Each charge is a feather-contracts obligation (holder owes the system) that bcc-housing collects from the holder's wallet at once. Holders may pay up to `Config.Setup.MaxTaxPrepayMonths` months ahead (a paid-until date, not a balance; paying ahead is a direct wallet payment, not an obligation). An empty wallet makes the house overdue: the obligation stays open and the house is suspended until staff release it and the holder pays, which settles that obligation. Deleting a house cancels its open obligation.
- **Selling:** back to the housing agent (paid straight into the wallet) or to another player, who must accept the offer before paying.
- **Storage** per house and per hotel room, with paid upgrade stages.
- **Furniture:** buy from vendors, place, move and sell back; the furniture book lists what you own.
- **Property deeds** as inventory items.
- **Hotels:** buy a room once, enter a private instanced room with its own storage.
- **Doors:** configured doors are locked for the holder on purchase; owners can lock more doors of their house.
- Translations: English, Romanian, Polish, German, French and Ukrainian (per player, through feather-core).

## Requirements

```cfg
ensure feather-mysql
ensure feather-core
ensure feather-character
ensure feather-notify
ensure feather-toolkit
ensure feather-menu-v2
ensure feather-economy
ensure feather-contracts
ensure feather-inventory
ensure feather-organizations
ensure feather-authority
ensure feather-property
ensure feather-jobs
ensure feather-routing
ensure feather-admin
ensure bcc-doorlocks
ensure bcc-housing
```

PolyZone is optional: house areas use a built-in polygon check; with PolyZone running (add `'@PolyZone/client.lua'` as the first client script) outlines are drawn too.

## Installation

1. Put the folder in `resources/[bcc]/bcc-housing`.
2. Import [sql/install_items.sql](sql/install_items.sql) once (`property_deed`, `furniture_book`), then restart feather-inventory.
3. Add the trust entries below, restart the changed resources, then `ensure bcc-housing`. Tables are created on start; configured houses and hotels are registered in feather-property.
4. Run `HousingReleaseSmokeTest` in the server console and expect every line to pass.
5. Give staff the housing role: `HousingAdminGrant <server id>` (Feather Admin administrators and owners are staff already).

### Trust entries

Keep the entries already in each list and add `['bcc-housing'] = true`:

| Resource | Lists |
|---|---|
| feather-property `config.lua` | `trustedReaders`, `trustedManagers`, `trustedAuditors` |
| feather-economy `config.lua` | `trustedReaders`, `trustedProvisioners`, `trustedTransactors`; and in `Config.IssueReasons`: `['bcc-housing'] = { ['housing.sold_to_agent'] = true, ['housing.furniture_sold'] = true }` |
| feather-contracts `config.lua` | `Config.Access.trustedIssuers` |
| feather-authority `config.lua` | `trustedReaders`, `trustedCapabilityRegistrars`, `trustedRoleCreators`, `trustedGrantors`, `trustedAssigners` |
| feather-jobs `config.lua` | `trustedReaders` |

And the service policy in **feather-admin `configs/service_policy.lua`**:

```lua
Config.servicePolicy = {
    -- existing domains unchanged
    ['feather-property'] = {
        ['bcc-housing'] = {
            ['property.property.manage'] = true, -- register houses and hotels, suspend/retire
            ['property.interest.manage'] = true  -- owners, tenants, transfers
        }
    },
    ['feather-economy'] = {
        -- existing entries unchanged
        ['bcc-housing'] = {
            ['economy.currency.issue'] = true    -- the agent buys houses and furniture back
        }
    },
    ['feather-contracts'] = {
        ['bcc-housing'] = {
            ['contracts.obligation.issue'] = true,   -- monthly tax and rent obligations
            ['contracts.obligation.cancel'] = true,  -- a deleted house cancels its open obligation
            ['contracts.obligation.default'] = true
        }
    }
}
```

feather-contracts must itself be trusted by feather-economy (`trustedReaders` and `trustedTransactors`, see the feather-contracts README). Without the Contracts entries, taxes and rent are not collected (each due date is retried every hour).

Without the `economy.currency.issue` grant, sales back to the agent stay queued (and furniture cannot be sold back); everything else works.

## Commands

| Command | Who | Purpose |
|---|---|---|
| `/HousingManager` | Staff | Create and manage houses |
| `/HouseMenu` | Holder | Open the house menu |
| `/editfurniture` | Holder | Edit nearby placed furniture |
| `/housingpoly` | Staff | Capture a PolyZone for a new house |
| `HousingReleaseSmokeTest` | Console | Read-only release check |
| `HousingAdminGrant <id>` / `HousingAdminRevoke <id>` | Console | Give or remove the housing staff role |
| `HousingPropertyStatus <houseid>` | Console | What feather-property records for a house |

## Configuration

See [configs/main.lua](configs/main.lua). Feather-specific settings:

| Setting | Purpose |
|---|---|
| `Config.Admin` | Staff capability and role, Feather Admin staff capabilities, realtor jobs (`jobs`) |
| `Config.Setup.MaxTaxPrepayMonths` | How many months of taxes/rent may be paid ahead |
| `Config.Setup.MaxStorageSlots` | Largest house or hotel storage |
| `Config.Setup.DefaultRentalCurrency` | `0` dollars, `1` gold |
| `Config.collectTaxes` | Turn monthly taxes and rent on |
| `Config.NotifyStyle` | feather-notify style |
| `currencyType` (per house) | `0` dollars, `1` gold (Rol tokens are not supported) |
| Agent `jobs` (configs/npcAgents.lua) | feather-jobs job keys and minimum grade ordinals |

## Custom Interiors Coords (Credits to punchedgang/siddwell740)

- Siddin3 = {x = -1103.15, y = -2252.92, z = 50.65}
- Siddin4 = {x = -63.74, y = 14.05, z = 76.6}

## Notes

- Do not place two pieces of furniture in exactly the same spot; selling one sells every piece at that spot.
- Deleting a house (staff menu) frees a configured house for sale again and retires a staff-created one.

## Credits

Original script by [BryceCanyonCounty](https://github.com/BryceCanyonCounty/bcc-housing). Feather port by [BCC-FeatherFramework](https://github.com/BCC-FeatherFramework/bcc-housing). Licensed GPL-3.0. Need help with the original gameplay? Join the BCC Discord: https://discord.gg/VrZEEpBgZJ

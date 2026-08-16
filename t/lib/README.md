# t/lib — test doubles and vendored modules

Nothing in this directory is installed. It exists so the unit tests can load
`ProxmodCron::API2::*`, `ProxmodCron.pm` and `ProxmodCron::Client` on a machine
with no Proxmox VE and no proxmod.

Most of the package needs none of it. `Config`, `Spec`, `Render`, `Registry`,
`State`, `Journal`, `Runs`, `Inventory`, `Sync`, `Store` and `Client` are all
loaded by `proxmod-cron-sync` from cron under a bare `perl`, so they have no PVE
dependency to stub out. That is the payoff of the PVE-free split, and it is why
this directory is as small as it is.

## Vendored, not stubbed

| File | From | |
|---|---|---|
| `PVE/RESTHandler.pm` | `../proxmod/t/lib` (itself copied from pve-manager 9.1.1) | real `register_method`, `map_path_to_methods` and `find_handler` |
| `PVE/JSONSchema.pm` | `../proxmod/t/lib` | `get_standard_option` only |
| `PVE/API2.pm` | `../proxmod/t/lib` | a miniature of the real API tree, with the real mount points |
| `Proxmod/API.pm` | `../proxmod/perl` | the actual extension API |
| `Proxmod/Log.pm` | `../proxmod/perl` | the actual logger |

`Proxmod::API` and `PVE::RESTHandler` are copies of the real thing on purpose.
The rules `t/06-api.t` asserts — a method with no `permissions` key is refused,
a duplicate path dies, a method registered where the parent has a regex
component is unreachable — are Proxmox's and proxmod's rules, and a friendlier
double would assert nothing. Re-copy after upgrading either dependency; do not
"fix" them here.

## Stubs

`PVE/Exception.pm`, `PVE/RPCEnvironment.pm`, `PVE/Tools.pm` and
`Proxmod/Registry.pm` are written for the tests and are scripted from them.
`PVE::RPCEnvironment` in particular is the one that matters: `t/09-authz.t`
drives the whole §8 model through a `check` that answers per (user, path,
privilege), so the authorization code is exercised against a decision table the
test writes rather than against a live cluster.

# The proxmod-cron extension API

Four surfaces, for four different jobs:

| Surface | Use it when |
|---|---|
| [Job-type plugins](#1-job-type-plugins) | your extension has work that should be schedulable |
| [`ProxmodCron::Client`](#2-proxmodcronclient) | your backend needs to create or manage jobs |
| [The REST API](#3-the-rest-api) | something outside the daemon talks to cron |
| [The `ProxmodCron` JS namespace](#4-the-proxmodcron-js-namespace) | your job type deserves a better editor than the generic one |

Declare the dependency in your manifest so `ProxmodCron` exists when your code
runs:

```json
{
    "id": "acme-backup",
    "order": 50,
    "requires": ["cron"],
    "backend": { "module": "Acme::Backup" },
    "frontend": { "assets": ["proxmod-acme-backup.js"] }
}
```

proxmod-cron sits at `order: 40`, below the default 50, so an extension at 50
that requires it loads after it. In `debian/control`:

```
Depends: proxmod (>= 0.2.0), proxmod-cron (>= 0.1.0)
```

---

## 1. Job-type plugins

A job type turns a validated config into an **argv**. That is the whole contract,
and it is an argv rather than a `run()` method for one reason: the effective
command then appears literally in `/etc/cron.d`, which is the property the whole
native-cron design exists to preserve.

```perl
package Acme::Backup::CronType;

use strict;
use warnings;

use base qw(ProxmodCron::JobType);

sub type        { 'acme-backup' }
sub title       { 'Acme Backup' }
sub icon_cls    { 'fa fa-archive' }
sub description { 'Back up one guest to an Acme target.' }

# The parameters this type accepts, beyond the common ones every job has.
# Used to validate a config, and to build a form when no JS one is registered.
sub properties {
    return {
        vmid   => { type => 'integer', minimum => 100, description => 'Guest to back up' },
        target => { type => 'string', maxLength => 256, description => 'Target path' },
        full   => { type => 'boolean', optional => 1, default => 0 },
    };
}

sub build_command {
    my ($class, $cfg) = @_;

    return ['/usr/lib/acme/backup',
            '--vmid',   $cfg->{vmid},
            '--target', $cfg->{target},
            $cfg->{full} ? '--full' : ()];
}

# Optional, and the one that decides delegation — see below.
sub required_privs {
    my ($class, $cfg) = @_;

    return [["/vms/$cfg->{vmid}", ['VM.Backup']]];
}

ProxmodCron::Registry::register(__PACKAGE__);

1;
```

### Registering it

`proxmod-cron-sync` calls `build_command` **from cron**, with no proxmod and no
PVE loaded. It cannot ask proxmod's registry which extensions are present, so
plugin modules are declared in a small manifest of their own — the same shape as
proxmod's `extensions.d`, for the same reason:

`/usr/share/proxmod-cron/types.d/acme-backup.json`

```json
{ "type": "acme-backup", "module": "Acme::Backup::CronType" }
```

Install that file and nothing else is needed; there is no maintainer script and
no call to make at load time. The module name is untainted against a strict
package-name pattern before `require` sees it.

**Your plugin module must load without PVE.** It is compiled inside cron's
`perl`, so `use PVE::…` anywhere in it — or in anything it uses — breaks every
render on the host, not just your job. Keep the plugin to config-in, argv-out;
put the PVE-dependent parts of your extension elsewhere.

A plugin that fails to load is reported, not fatal. Its jobs render as **disabled
comment lines naming the missing type** — the only honest outcome, because
guessing a command is worse and silently dropping the job is worse still.

### The base class

| Method | Default | |
|---|---|---|
| `type()` | dies | the id, and the value of `PROXMOD_CRON_TYPE` |
| `title()` | `type()` | shown in the UI |
| `icon_cls()` | `'fa fa-cog'` | |
| `description()` | `''` | shown in the type combo and the API viewer |
| `properties()` | `{}` | `{ name => { type, optional, default, minimum, maximum, maxLength, items, description } }` |
| `build_command($cfg)` | dies | **required** — return an arrayref |
| `required_privs($cfg)` | `[]` | `[[path, [privs]], …]`; every pair must pass |
| `run_as()` | `'root'` | the crontab user field, fixed by you, not by the caller |
| `track_default()` | `1` | whether new jobs of this type record their runs |

Supported `properties` types are `string`, `integer`, `number`, `boolean` and
`array` (with `items`). Validation is proxmod-cron's own rather than
`PVE::JSONSchema`'s — the accepted shapes are a small subset, and depending on
PVE would mean the renderer could not run.

### `required_privs`, and what an empty one means

```perl
sub required_privs {
    my ($class, $cfg) = @_;
    return [["/vms/$cfg->{vmid}", ['VM.Backup']]];
}
```

This makes your type **delegable**: a user who holds `VM.Backup` on `/vms/101`
can create, edit, run and delete a job of your type for VM 101 through
`delegated-jobs/`, without `Sys.Modify` on the node, and sees only their own jobs
in the list.

**Returning an empty list — the default — means "not delegable."** Only
`Sys.Modify` on the scope can manage such a job. The built-in `command` type
returns empty deliberately: a command job is arbitrary root execution and there
is no ACL path that honestly describes it.

So: if your job is *about* an object PVE already has an ACL path for, declare it.
If it is not, do not invent one — leave `required_privs` empty and let
`Sys.Modify` be the gate.

Note what delegation deliberately does **not** allow, whatever you declare: a
delegated caller cannot set `user`, cannot set `track`, and cannot change a job's
`type`. Each is a route to more than the delegation granted. The crontab user is
pinned to your `run_as()`.

---

## 2. `ProxmodCron::Client`

> **The client does no ACL checking.** It runs inside `pvedaemon` as root and has
> no authenticated user to check against — it is the layer *below* authorization,
> the same relationship `PVE::Jobs` has to `PVE::API2::Cluster::Jobs`. If you are
> acting on behalf of a user, check first:
>
> ```perl
> $rpcenv->check($authuser, "/nodes/$node", ['Sys.Modify']);
> $cron->ensure('node', $id, $cfg);
> ```
>
> Missing this writes a privilege escalation into an otherwise correct extension.

```perl
use ProxmodCron::Client;

sub proxmod_register {
    my ($class, $api) = @_;

    my $cron = ProxmodCron::Client->new($api);   # $api is your Proxmod::API

    $cron->ensure('cluster', 'acme-nightly', {
        type     => 'acme-backup',
        schedule => '30 3 * * *',
        comment  => 'nightly backup of VM 101',
        nodes    => ['pve1'],
        vmid     => 101,
        target   => '/mnt/pbs',
    });
}
```

Ownership comes from `$api->id`, never from an argument — which is why this is an
object rather than a set of class methods. If the owner were a parameter, one
extension could claim another's jobs or forge `origin: user`.

| Method | |
|---|---|
| `new($api)` | `$api` is your `Proxmod::API`; outside a daemon, a plain extension id |
| `owner()` | the id every write is stamped with |
| `list($scope, %opts)` | every job in the scope, sorted by id; `mine => 1` for only yours |
| `get($scope, $id)` | one job with defaults applied, or `undef` |
| `create($scope, $id, $cfg)` | dies if the id is taken |
| `ensure($scope, $id, $cfg)` | **the method to call from `proxmod_register`** |
| `update($scope, $id, $delta)` | merge into one of *your* jobs |
| `set_enabled($scope, $id, $enabled)` | switch one of your jobs on or off |
| `delete($scope, $id)` | remove one of your jobs |
| `status($scope, $id)` | last run from the cache: run id, timestamps, exit, output tail |
| `runs($scope, $id, %opts)` | run history from journald; `since`, `until`, `limit` |
| `log($runid, %opts)` | one run's captured output; `cursor`, `limit` |
| `sync()` | render both scopes now (the write methods already do) |
| `types()` | the registered types, exactly as `GET types` returns them |

`$scope` is `'cluster'` or `'node'`. Every method dies with a message naming the
job on failure; a die inside `proxmod_register` disables **your** extension and
nothing else.

### The three rules worth reading twice

**`ensure()` never overwrites `enabled` on a job that already exists.** You call
it on every daemon start. If it wrote `enabled` each time, an administrator's
decision to stop your job would be silently reverted seconds after the next
restart, and the enable/disable split would be worth nothing. `ensure` writes the
schedule, your type's parameters and the comment; `enabled` is set only at
creation. `set_enabled()` is deliberately separate and conspicuous — think hard
before calling it on a schedule rather than in response to something the
administrator did.

**Do not delete your jobs on shutdown or uninstall.** A job whose owner is no
longer loaded is flagged *orphaned*, keeps running, and becomes removable through
the UI. Deleting from a shutdown path would throw away an administrator's
configuration on every daemon restart.

**Your jobs are read-only to administrators except for enable/disable.** They can
see the job, they can stop it, and they cannot edit or remove it while your
extension is loaded. `update` and `delete` on another extension's job die.

---

## 3. The REST API

`/cluster/proxmod/cron` and `/nodes/{node}/proxmod/cron`.

### Cluster scope

| Method | Path | Privilege on `/` |
|---|---|---|
| `GET` | `jobs` | `Sys.Audit` |
| `POST` | `jobs` | `Sys.Modify` |
| `GET` | `jobs/{id}` | `Sys.Audit` |
| `PUT` | `jobs/{id}` | `Sys.Modify` |
| `PUT` | `jobs/{id}/enabled` | `Sys.Modify` — **any origin** |
| `DELETE` | `jobs/{id}` | `Sys.Modify` |
| `POST`/`PUT`/`DELETE` | `delegated-jobs[/{id}]` | delegated (see §1) |
| `GET` | `types` | any authenticated user |
| `GET` | `schedule` | any authenticated user |
| `GET` | `permissions` | any authenticated user |

### Node scope

| Method | Path | Privilege on `/nodes/{node}` |
|---|---|---|
| `GET` | `jobs` | `Sys.Audit` — node jobs plus the cluster jobs targeting this node |
| `POST`/`PUT`/`DELETE` | `jobs[/{id}]` | `Sys.Modify` |
| `PUT` | `jobs/{id}/enabled` | `Sys.Modify` — **any origin** |
| `POST`/`PUT`/`DELETE` | `delegated-jobs[/{id}]` | delegated |
| `POST` | `jobs/{id}/run` | `Sys.Modify`, or delegated → returns a UPID |
| `GET` | `jobs/{id}/status` | `Sys.Audit` |
| `GET` | `jobs/{id}/runs` | `Sys.Audit`, or delegated |
| `GET` | `runs/{runid}` | as above |
| `GET` | `runs/{runid}/log` | **`Sys.Syslog`**, or delegated |
| `GET` | `journal` | `Sys.Syslog` |
| `GET` | `journal-status` | `Sys.Audit` |
| `GET` | `inventory` | `Sys.Audit` |
| `POST` | `sync` | `Sys.Modify` |
| `GET` | `types` / `permissions` | any authenticated user |

Every mutating method is `protected` — `pveproxy` runs as `www-data` and cannot
write `/etc/cron.d`, `/etc/proxmod` or `/etc/pve`. **Every run and log read is
`protected` too**, for a related reason: `www-data` is not in the
`systemd-journal` group, and an unprotected method would return an empty history
that looks exactly like "this job never ran".

### Things that will catch you

- **`POST jobs` ignores `origin` and `owner` in the body** and always writes
  `origin: user`. The extension-owned origin is reachable only through
  `ProxmodCron::Client`, in-process, which is what makes it mean anything.
- **`PUT jobs/{id}` rejects an `enabled` key** and points you at
  `jobs/{id}/enabled`. Enabling is the only mutation permitted on an
  extension-owned job, so it is enforced by routing rather than by a conditional
  inside a general update handler. There is one way to do it.
- **A one-element array arrives as a scalar.** PVE's parameter parser builds an
  array only when a key repeats, so `command=/bin/true` reaches the method as a
  string while `command=/bin/true&command=-x` reaches it as a list. The API layer
  coerces at the boundary; `ProxmodCron::Client` is in-process and wants real
  arrays.
- **Run history is node-scoped**, because journald is. There is no cluster-wide
  run history endpoint and the cluster grid has no last-result column — a
  cluster-wide one would mean one request per row per node, or a number that
  silently means "whichever node answered".
- **`runs/{runid}/log` paginates by journald cursor**, not by offset, so a live
  tail cannot skip or repeat a line as new ones arrive mid-poll.

### Row shape

Every row from `GET jobs` and `GET jobs/{id}` carries resolved capability flags,
so you never re-derive the rules:

```json
{ "id": "acme-nightly", "type": "acme-backup", "scope": "cluster",
  "origin": "extension", "owner": "acme-backup", "orphaned": false,
  "enabled": false, "schedule": "30 3 * * *", "next_run": 1771200000,
  "can_toggle": true, "can_edit": false, "can_delete": false,
  "can_run": true, "can_modify": false, "type_available": 1 }
```

Each flag is the **AND** of the origin rule and the caller's privileges, computed
by one helper that the write methods also call — so a flag cannot claim something
the enforcement would refuse.

---

## 4. The `ProxmodCron` JS namespace

Your asset runs after proxmod-cron's if your manifest declares
`"requires": ["cron"]` and an `order` above 40. Guard anyway — an administrator
can disable an extension without removing the package:

```js
(function () {
    'use strict';

    if (typeof ProxmodCron === 'undefined' || !ProxmodCron.registerType) {
        return;
    }
    …
})();
```

### `ProxmodCron.registerType(spec)`

Replace the generic form the editor builds from your property schema with a good
one. This is an **improvement, never a requirement**: a type with no registered
form still gets a working editor.

```js
ProxmodCron.registerType({
    type: 'acme-backup',
    title: 'Acme Backup',
    iconCls: 'fa fa-archive',

    // Ext field configs. Each field's `name` is the config key it writes.
    formItems: function (ctx) {          // ctx: { scope, nodename, job }
        return [
            { xtype: 'pveGuestIDSelector', name: 'vmid', fieldLabel: gettext('Guest') },
            { xtype: 'textfield', name: 'target', fieldLabel: gettext('Target') },
            { xtype: 'proxmoxcheckbox', name: 'full', uncheckedValue: 0,
              fieldLabel: gettext('Full backup') },
        ];
    },

    // Optional. What the grid's Command column shows for your jobs.
    renderCommand: function (job) {
        return 'backup VM ' + job.vmid + ' → ' + job.target;
    },
});
```

For an array-valued property, use `xtype: 'proxmodCronArgv'` — a textarea taking
one element per line whose submitted value is a real array.

Both callbacks run inside `Proxmod.guard`, so a throw costs your form and not the
panel. **`renderCommand`'s return value is HTML-encoded before it is displayed**
— return text, not markup.

### The rest of the namespace

```js
ProxmodCron.version                                  // '0.1.0'

ProxmodCron.api.list(scope, opts)                    // scope: 'cluster' | 'node'
ProxmodCron.api.get(scope, id, opts)
ProxmodCron.api.create(scope, params, opts)
ProxmodCron.api.update(scope, id, params, opts)
ProxmodCron.api.remove(scope, id, opts)
ProxmodCron.api.setEnabled(scope, id, enabled, opts)
ProxmodCron.api.run(node, id, opts)                  // -> UPID
ProxmodCron.api.runs(node, id, opts)
ProxmodCron.api.log(node, runid, opts)
ProxmodCron.api.getRun(node, runid, opts)
ProxmodCron.api.journal(node, opts)
ProxmodCron.api.inventory(node, opts)
ProxmodCron.api.sync(node, opts)
ProxmodCron.api.types(scope, node, callback, opts)   // callback(data)
ProxmodCron.api.permissions(scope, node, callback, opts)
ProxmodCron.api.schedule(value, count, callback, opts)
ProxmodCron.api.url(path, node)
ProxmodCron.api.storeUrl(path, node)                 // for a `proxmox` proxy

ProxmodCron.openEditor({ scope, node, id, type, job, perms, callback })
ProxmodCron.openRunLog({ node: nodename, run: runid })

ProxmodCron.format.encode(value)                     // Ext.String.htmlEncode, null-safe
ProxmodCron.format.timestamp(seconds)
ProxmodCron.format.duration(ms)
```

`opts` is a `Proxmod.api.request` config: `params`, `success`, `failure`,
`waitMsgTarget`, and `node` where the signature does not already take one. As
everywhere in proxmod, **`success` receives the whole response** — what the Perl
method returned is at `response.result.data`. The three callback-taking helpers
(`types`, `permissions`, `schedule`) unwrap it for you.

Widgets you can drop into your own panels:

| xtype | |
|---|---|
| `proxmodCronJobGrid` | the job grid; config `scope`, `nodename` |
| `proxmodCronRuns` | run history; config `nodename`, then `setJob(id)` |
| `proxmodCronRunLog` | one run's output; config `nodename`, `runid` |
| `proxmodCronInventory` | every cron entry on the host; config `nodename` |
| `proxmodCronJournal` | the node's proxmod-cron journal; config `nodename` |
| `proxmodCronSchedule` | the schedule field, with a live next-runs preview |
| `proxmodCronArgv` | a textarea whose value is an array, one element per line |

The job grid fires two events you can listen for: `proxmodcronperms`
`(grid, permissions)` once the caller's rights are known, and `proxmodcronrun`
`(grid, id, upid)` when a job is started by hand.

### Two rules that are not style

1. **Encode everything.** Job comments, commands and — above all — captured job
   output are attacker-influenced text rendered in the hypervisor's admin
   interface. A stored XSS there runs in an authenticated root session. Every
   value that reaches a renderer, template or tooltip goes through
   `Ext.String.htmlEncode`; for a `data-qtip` attribute, encode **twice** (once so
   the tooltip renders characters rather than interpreting them, once so the
   attribute cannot be closed early).
2. **Never re-derive who may do what.** Every row carries `can_edit`,
   `can_delete`, `can_toggle`, `can_run` and `can_modify`, already folding in both
   the privilege check and the origin rule. A second copy of that logic in
   JavaScript is a copy that will drift — and the server checks every call
   regardless.

Your asset is served **unauthenticated** to anyone who can reach port 8006
`[PVE-F-023]`. No hostnames, no tokens, no internal paths in it.

---

## A note on secrets

Anything a tracked job prints is stored in the journal, readable by any
`Sys.Syslog` holder and by anyone with shell access to the host — a wider audience
than the API, and wider than the root mailbox cron output used to go to. If your
job type can print credentials, connection strings or ticket contents, either
stop it printing them or set `keep_output => 0` on the jobs you create. Job
definitions are not a secret store either: `/etc/proxmod/cron.cfg` is mode `0600`
and `/etc/pve` enforces its own permissions, but nothing in either is encrypted
and both are readable by root on every node.

// proxmod-cron — the web interface.
//
// This file is served WITHOUT AUTHENTICATION [PVE-F-023]. Anyone who can reach
// port 8006 can read it. No hostnames, no tokens, no internal paths.
//
// There is no module loader and no build step: one concatenated bundle, one
// global scope, ES5. Everything below is wrapped in an IIFE and touches exactly
// one global of its own, `ProxmodCron`, which is also the API other extensions
// build on (docs/extension-api.md).
//
// A thrown exception in a component's initComponent blanks that panel, and one
// thrown in an unguarded listener is uncaught — so anything we attach ourselves
// goes through Proxmod.guard.
//
// Three rules that are not style:
//
//   1. Every value that reaches a renderer, a template or a tooltip goes
//      through Ext.String.htmlEncode. Job comments, commands and — above all —
//      captured job output are attacker-influenced text rendered in the
//      hypervisor's admin interface. A stored XSS here runs in an
//      authenticated root session.
//   2. The UI never re-derives who may do what. Every row carries can_edit /
//      can_delete / can_toggle, already folding in both the privilege check
//      (§8) and the origin rule (§2.1). A second copy of that logic in
//      JavaScript is a copy that will drift, and the server checks every call
//      regardless.
//   3. No 'use strict'. ExtJS resolves callParent by reading Function.caller on
//      the calling method, and V8 hands out null for that whenever the caller
//      is a strict-mode function — every callParent below would die inside
//      ext-all.js with "Cannot read properties of null (reading 'apply')".
//      Strictness is inherited by nested functions, so it is the whole file or
//      nothing.

(function () {
    // Deliberately sloppy mode: callParent needs it. See rule 3 above.

    // proxmod can be disabled by an administrator without this package being
    // removed, and then there is nothing to register against.
    if (typeof Proxmod === 'undefined' || !Proxmod.ui) {
        return;
    }

    var EXT = 'cron';
    var VERSION = '202608.22.0';

    // PVE's own, always present in the workspace. The fallback is for the
    // moment before the translation table is built, not for a page without it.
    var gettext = window.gettext || function (s) { return s; };

    var ProxmodCron = window.ProxmodCron || {};
    window.ProxmodCron = ProxmodCron;

    ProxmodCron.version = VERSION;

    // -----------------------------------------------------------------------
    // Encoding and formatting
    // -----------------------------------------------------------------------

    function enc(value) {
        if (value === undefined || value === null) {
            return '';
        }
        return Ext.String.htmlEncode(String(value));
    }

    // A tooltip is HTML inside an HTML attribute, so untrusted text has to
    // survive two decodings and is therefore encoded twice: once so the tooltip
    // renders the characters rather than interpreting them, and once so the
    // attribute cannot be closed early. Encoding only once puts the raw text
    // back into the DOM the moment the browser decodes the attribute.
    function qtip(html) {
        return 'data-qtip="' + Ext.String.htmlEncode(html) + '"';
    }

    function stamp(seconds) {
        if (!seconds) {
            return '';
        }
        return Ext.Date.format(new Date(seconds * 1000), 'Y-m-d H:i:s');
    }

    function duration(ms) {
        if (ms === undefined || ms === null) {
            return '';
        }
        if (ms < 1000) {
            return ms + 'ms';
        }
        var s = Math.round(ms / 100) / 10;
        if (s < 60) {
            return s + 's';
        }
        var mins = Math.floor(s / 60);
        var rest = Math.round(s % 60);
        if (mins < 60) {
            return mins + 'm ' + rest + 's';
        }
        return Math.floor(mins / 60) + 'h ' + (mins % 60) + 'm';
    }

    ProxmodCron.format = {
        encode: enc,
        timestamp: stamp,
        duration: duration,
    };

    // -----------------------------------------------------------------------
    // The REST surface — ProxmodCron.api
    //
    // Thin wrappers over Proxmod.api, which builds the URL from the extension
    // id so that no caller has to know it. `scope` is 'cluster' or 'node';
    // `node` is ignored for the cluster scope and required for the node one.
    // -----------------------------------------------------------------------

    function nodeOf(scope, node) {
        return scope === 'cluster' ? undefined : node;
    }

    function request(method, path, node, opts) {
        var config = Ext.apply({}, opts || {});
        config.ext = EXT;
        config.path = path;
        config.method = method;
        if (node !== undefined) {
            config.node = node;
        }
        return Proxmod.api.request(config);
    }

    // The whole response reaches the callback; what the Perl method returned is
    // at response.result.data. Unwrapping it once here is worth the wrapper.
    function unwrap(callback) {
        return function (response) {
            callback(response && response.result ? response.result.data : undefined,
                response);
        };
    }

    ProxmodCron.api = {
        url: function (path, node) {
            return Proxmod.api.url(EXT, path, node);
        },

        storeUrl: function (path, node) {
            return Proxmod.api.storeUrl(EXT, path, node);
        },

        request: function (opts) {
            var config = Ext.apply({}, opts || {});
            config.ext = EXT;
            return Proxmod.api.request(config);
        },

        list: function (scope, opts) {
            return request('GET', 'jobs', nodeOf(scope, (opts || {}).node), opts);
        },

        get: function (scope, id, opts) {
            return request('GET', 'jobs/' + id, nodeOf(scope, (opts || {}).node), opts);
        },

        create: function (scope, params, opts) {
            var config = Ext.apply({}, opts || {});
            config.params = params;
            return request('POST', 'jobs', nodeOf(scope, config.node), config);
        },

        update: function (scope, id, params, opts) {
            var config = Ext.apply({}, opts || {});
            config.params = params;
            return request('PUT', 'jobs/' + id, nodeOf(scope, config.node), config);
        },

        remove: function (scope, id, opts) {
            return request('DELETE', 'jobs/' + id, nodeOf(scope, (opts || {}).node), opts);
        },

        // Its own endpoint, not a field on update: enabling and disabling is
        // the one mutation permitted on an extension-owned job, and a separate
        // path means that rule is enforced by routing (§7).
        setEnabled: function (scope, id, enabled, opts) {
            var config = Ext.apply({}, opts || {});
            config.params = { enabled: enabled ? 1 : 0 };
            return request('PUT', 'jobs/' + id + '/enabled', nodeOf(scope, config.node),
                config);
        },

        run: function (node, id, opts) {
            return request('POST', 'jobs/' + id + '/run', node, opts);
        },

        runs: function (node, id, opts) {
            return request('GET', 'jobs/' + id + '/runs', node, opts);
        },

        log: function (node, runid, opts) {
            return request('GET', 'runs/' + runid + '/log', node, opts);
        },

        getRun: function (node, runid, opts) {
            return request('GET', 'runs/' + runid, node, opts);
        },

        journal: function (node, opts) {
            return request('GET', 'journal', node, opts);
        },

        journalStatus: function (node, opts) {
            return request('GET', 'journal-status', node, opts);
        },

        inventory: function (node, opts) {
            return request('GET', 'inventory', node, opts);
        },

        sync: function (node, opts) {
            return request('POST', 'sync', node, opts);
        },

        types: function (scope, node, callback, opts) {
            return request('GET', 'types', nodeOf(scope, node),
                Ext.apply({ success: unwrap(callback) }, opts || {}));
        },

        // Whether the node answering this request is quorate. Cluster-scoped
        // jobs stand down on a node that is not, so a datacenter Cron tab that
        // did not say so would be showing a schedule that is not running.
        membership: function (callback, opts) {
            return request('GET', 'membership', undefined,
                Ext.apply({ success: unwrap(callback) }, opts || {}));
        },

        // What the caller may actually do, computed server-side with the same
        // helper the write methods enforce with (§8.5). The UI disables what is
        // not permitted; it does not decide it.
        permissions: function (scope, node, callback, opts) {
            return request('GET', 'permissions', nodeOf(scope, node),
                Ext.apply({ success: unwrap(callback) }, opts || {}));
        },

        // Pure arithmetic on a schedule string — it reads nothing, needs no
        // node, and is open to any authenticated user.
        schedule: function (value, count, callback, opts) {
            return request('GET', 'schedule', undefined, Ext.apply({
                params: { schedule: value, count: count || 3 },
                success: unwrap(callback),
            }, opts || {}));
        },
    };

    // -----------------------------------------------------------------------
    // The job-type registry — ProxmodCron.registerType
    //
    // A plugin's backend already publishes a property schema through GET types,
    // and the editor builds a usable form from it unaided. Registering here is
    // how an extension replaces that generic form with a good one; it is an
    // improvement, never a requirement, so an unknown type still renders.
    // -----------------------------------------------------------------------

    var TYPES = {};

    ProxmodCron.registerType = function (spec) {
        if (!spec || !spec.type) {
            Proxmod.log.error('proxmod-cron: registerType needs a type');
            return false;
        }
        TYPES[spec.type] = spec;
        return true;
    };

    ProxmodCron.typeSpec = function (type) {
        return TYPES[type];
    };

    // -----------------------------------------------------------------------
    // Row renderers
    // -----------------------------------------------------------------------

    // Where a job came from, in the words §2.1 uses. An orphan is called one
    // because that is what explains the row: its owner is gone, which is
    // exactly why Remove has come back to life.
    function renderSource(value, meta, record) {
        var data = record.data;

        if (data.origin !== 'extension') {
            return enc(gettext('Custom'));
        }

        var owner = data.owner || gettext('unknown');

        if (data.orphaned) {
            meta.tdAttr = qtip(enc(Ext.String.format(
                gettext('Created by {0}, which is no longer installed.'), owner)));
            return '<span class="proxmod-cron-warning">'
                + enc(owner) + ' ' + enc(gettext('(orphaned)')) + '</span>';
        }

        meta.tdAttr = qtip(enc(Ext.String.format(
            gettext('Managed by {0}. You can enable or disable it here; to change'
                + ' or remove it, use that extension.'), owner)));
        return enc(owner);
    }

    function renderSchedule(value, meta, record) {
        if (record.data.schedule_error) {
            meta.tdAttr = qtip(enc(record.data.schedule_error));
            return '<span class="proxmod-cron-error">' + enc(value) + '</span>';
        }
        return enc(value);
    }

    function renderNextRun(value, meta, record) {
        if (record.data.enabled === false || record.data.enabled === 0) {
            return '<span class="proxmod-cron-muted">' + enc(gettext('disabled')) + '</span>';
        }
        if (!value) {
            return '-';
        }
        return enc(stamp(value));
    }

    // The command as it will actually be run. A registered type may render its
    // own; otherwise the argv is shown as an argv, because that is what gets
    // executed — no string is ever handed to a shell.
    function renderCommand(value, meta, record) {
        var data = record.data;
        var spec = TYPES[data.type];
        var text;

        if (spec && spec.renderCommand) {
            text = Proxmod.guard('proxmod-cron renderCommand for ' + data.type,
                function () { return spec.renderCommand(data); });
        }

        if (text === undefined || text === null) {
            if (Ext.isArray(data.command)) {
                text = data.command.join(' ');
            } else if (data.command) {
                text = String(data.command);
            }
        }

        if (text === undefined || text === null || text === '') {
            if (!data.type_available) {
                meta.tdAttr = qtip(enc(gettext('This job type is not installed on'
                    + ' this node. The job is rendered as a disabled comment line'
                    + ' rather than run with a guessed command.')));
                return '<span class="proxmod-cron-error">'
                    + enc(Ext.String.format(gettext('type {0} is not installed'),
                        data.type)) + '</span>';
            }
            return '<span class="proxmod-cron-muted">' + enc(data.type || '') + '</span>';
        }

        meta.tdAttr = qtip(enc(text));
        return enc(text);
    }

    function renderNodes(value) {
        if (!value || !value.length) {
            return enc(gettext('all nodes'));
        }
        return enc(value.join(', '));
    }

    // 'all' is replication and 'any' is placement — two different things a
    // cluster job can be, and the grid has to say which without a legend.
    function renderRunOn(value) {
        if (value === 'any') {
            return enc(gettext('one node per run'));
        }
        return '<span class="proxmod-cron-muted">'
            + enc(gettext('every node')) + '</span>';
    }

    // Which node claimed the last scheduled run of a job that moves. A holder
    // still marked running long after its tick is a node that died mid-run:
    // nothing re-runs that tick by design, so this is where it is visible.
    function renderLastHolder(value, meta, record) {
        if ((record.data.run_on || 'all') !== 'any') {
            return '<span class="proxmod-cron-muted">-</span>';
        }

        var holder = record.data.last_holder;

        if (!holder || !holder.node) {
            return '<span class="proxmod-cron-muted">'
                + enc(gettext('not claimed yet')) + '</span>';
        }

        var when = holder.tick ? stamp(holder.tick) : gettext('an unknown time');

        meta.tdAttr = qtip(enc(Ext.String.format(
            gettext('Scheduled run of {0}, claimed by {1}'), when, holder.node)));

        if (holder.state === 'running') {
            return enc(holder.node) + ' <span class="proxmod-cron-muted">('
                + enc(gettext('running')) + ')</span>';
        }
        if (holder.state && holder.state !== 'ok') {
            return enc(holder.node) + ' <span class="proxmod-cron-error">('
                + enc(holder.state) + ')</span>';
        }

        return enc(holder.node);
    }

    // The §5.5 cache, which is a cache: an empty answer means "no record", not
    // "never ran". `never run` on a job whose schedule has already come round is
    // the single most useful thing this grid shows, so it is styled as a warning
    // rather than as absence.
    function renderLastResult(value, meta, record) {
        var run = record.data.last_run;

        if (!run || !run.run) {
            return '<span class="proxmod-cron-warning">'
                + enc(gettext('never run')) + '</span>';
        }

        var text;
        var cls = 'proxmod-cron-ok';

        if (run.state === 'ok') {
            text = gettext('OK');
        } else if (run.state === 'killed') {
            text = Ext.String.format(gettext('killed (signal {0})'), run.signal);
            cls = 'proxmod-cron-error';
        } else if (run.state === 'failed') {
            text = Ext.String.format(gettext('exit {0}'), run.exit);
            cls = 'proxmod-cron-error';
        } else if (run.state === 'running') {
            text = gettext('running');
            cls = 'proxmod-cron-muted';
        } else {
            text = run.state || gettext('unknown');
            cls = 'proxmod-cron-warning';
        }

        var lines = [
            enc(gettext('Started')) + ': ' + enc(stamp(run.started)),
            enc(gettext('Duration')) + ': ' + enc(duration(run.duration_ms)),
        ];

        if (run.lines) {
            lines.push(enc(gettext('Output lines')) + ': ' + enc(run.lines)
                + (run.truncated ? ' ' + enc(gettext('(truncated)')) : ''));
        }

        // The tail is job output like any other, so the server strips it for a
        // caller without Sys.Syslog (§8.2) and it is simply absent here.
        if (Ext.isArray(run.tail) && run.tail.length) {
            lines.push('');
            Ext.each(run.tail, function (line) { lines.push(enc(line)); });
        }

        meta.tdAttr = qtip(lines.join('<br>'));

        return '<span class="' + cls + '">' + enc(text) + '</span>';
    }

    // -----------------------------------------------------------------------
    // The schedule field
    //
    // PVE's own pveCalendarEvent speaks systemd calendar syntax, which is not
    // cron syntax, so this is ours: free text with presets, and a live preview
    // of the next runs from the server's parser rather than a second one here.
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.form.ScheduleField', {
        extend: 'Ext.form.FieldContainer',
        xtype: 'proxmodCronSchedule',

        layout: 'anchor',
        defaults: { anchor: '100%' },

        fieldLabel: gettext('Schedule'),

        // The FieldContainer is not itself a field, so the form reads the combo
        // inside it. Exposing the name here keeps the caller's config honest.
        name: 'schedule',

        getValue: function () {
            return this.down('combobox').getValue();
        },

        setValue: function (value) {
            this.down('combobox').setValue(value);
            this.preview();
            return this;
        },

        setReadOnlyState: function (readOnly) {
            this.down('combobox').setReadOnly(readOnly);
            return this;
        },

        preview: function () {
            var me = this;
            var value = me.getValue();
            var out = me.down('#preview');

            if (!out) {
                return;
            }

            if (!value) {
                out.setValue('');
                return;
            }

            ProxmodCron.api.schedule(value, 3, function (data) {
                if (me.destroyed || me.destroying) {
                    return;
                }
                if (!data || !data.valid) {
                    out.setValue('<span class="proxmod-cron-error">'
                        + enc(data && data.error ? data.error
                            : gettext('not a valid schedule')) + '</span>');
                    return;
                }
                var when = [];
                Ext.each(data.next || [], function (t) { when.push(enc(stamp(t))); });
                out.setValue(enc(gettext('Next runs')) + ': '
                    + (when.length ? when.join(', ') : enc(gettext('never'))));
            }, {
                // A preview that cannot be fetched is not an error worth a modal
                // dialog on top of the form the user is filling in.
                failure: function () {
                    if (!me.destroyed) {
                        out.setValue('');
                    }
                },
            });
        },

        initComponent: function () {
            var me = this;

            var presets = [
                ['@hourly', gettext('every hour')],
                ['@daily', gettext('every day at midnight')],
                ['@weekly', gettext('every Sunday at midnight')],
                ['@monthly', gettext('on the first of every month')],
                ['@reboot', gettext('once, at boot')],
                ['*/15 * * * *', gettext('every 15 minutes')],
                ['0 * * * *', gettext('every hour, on the hour')],
                ['30 2 * * *', gettext('every day at 02:30')],
                ['0 4 * * 0', gettext('every Sunday at 04:00')],
            ];

            var data = [];
            Ext.each(presets, function (row) {
                data.push({ value: row[0], text: row[0] + '  —  ' + row[1] });
            });

            me.items = [
                {
                    xtype: 'combobox',
                    name: me.name,
                    hideLabel: true,
                    editable: true,
                    queryMode: 'local',
                    displayField: 'text',
                    valueField: 'value',
                    allowBlank: false,
                    emptyText: '30 2 * * *',
                    store: { fields: ['value', 'text'], data: data },
                    listeners: {
                        change: function () {
                            Proxmod.guard('proxmod-cron schedule preview', function () {
                                me.previewTask.delay(400);
                            });
                        },
                    },
                },
                {
                    xtype: 'displayfield',
                    itemId: 'preview',
                    hideLabel: true,
                    cls: 'proxmod-cron-muted',
                    // The value is built out of encoded pieces above; the field
                    // must not encode it a second time or the markup shows.
                    htmlEncode: false,
                },
            ];

            me.previewTask = new Ext.util.DelayedTask(function () {
                Proxmod.guard('proxmod-cron schedule preview', function () {
                    me.preview();
                });
            });

            me.callParent();

            me.on('destroy', function () { me.previewTask.cancel(); });
        },
    });

    // -----------------------------------------------------------------------
    // Type-specific fields
    // -----------------------------------------------------------------------

    // An argv, one element per line. Deliberately not a single text box: a
    // command is an array end to end and no string is ever handed to a shell,
    // so asking for a shell line here would be asking for something this
    // extension will not do with it.
    Ext.define('ProxmodCron.form.ArgvField', {
        extend: 'Ext.form.field.TextArea',
        xtype: 'proxmodCronArgv',

        grow: true,
        growMin: 60,
        growMax: 200,

        proxmodCronValue: function () {
            var out = [];
            Ext.each(String(this.getValue() || '').split('\n'), function (line) {
                var text = line.replace(/^\s+|\s+$/g, '');
                if (text !== '') {
                    out.push(text);
                }
            });
            return out;
        },

        setValue: function (value) {
            if (Ext.isArray(value)) {
                value = value.join('\n');
            }
            return this.callParent([value]);
        },
    });

    // A form for a job type, from whatever we know about it: a registered JS
    // form if the owning extension supplied one, otherwise built from the
    // property schema the API published. An unknown type still gets an editor.
    function typeFields(type, schema, ctx) {
        var spec = TYPES[type];

        if (spec && spec.formItems) {
            var items = Proxmod.guard('proxmod-cron formItems for ' + type,
                function () { return spec.formItems(ctx); });
            if (Ext.isArray(items)) {
                return items;
            }
        }

        var props = (schema && schema.properties) || {};
        var out = [];

        Ext.Object.each(props, function (key, prop) {
            var field = {
                name: key,
                fieldLabel: key,
                allowBlank: prop.optional ? true : false,
            };

            if (prop.description) {
                field.autoEl = { tag: 'div', 'data-qtip': prop.description };
            }

            if (prop.type === 'boolean') {
                field.xtype = 'proxmoxcheckbox';
                field.uncheckedValue = 0;
                if (prop['default'] !== undefined) {
                    field.value = prop['default'] ? 1 : 0;
                }
            } else if (prop.type === 'array') {
                field.xtype = 'proxmodCronArgv';
                field.fieldLabel = key + ' ' + gettext('(one per line)');
            } else if (prop.type === 'integer' || prop.type === 'number') {
                field.xtype = 'numberfield';
                field.allowDecimals = prop.type === 'number';
                if (prop.minimum !== undefined) { field.minValue = prop.minimum; }
                if (prop.maximum !== undefined) { field.maxValue = prop.maximum; }
                if (prop['default'] !== undefined) { field.value = prop['default']; }
            } else {
                field.xtype = 'textfield';
                if (prop.maxLength) { field.maxLength = prop.maxLength; }
                if (prop['default'] !== undefined) { field.value = prop['default']; }
            }

            out.push(field);
        });

        if (!out.length) {
            out.push({
                xtype: 'displayfield',
                hideLabel: true,
                value: enc(gettext('This job type takes no parameters.')),
            });
        }

        return out;
    }

    // proxmoxcheckbox is widget-toolkit's; fall back to a plain one rather than
    // failing to build the form on a host that does not have it.
    function checkbox(config) {
        var xtype = Ext.ClassManager.getByAlias('widget.proxmoxcheckbox')
            ? 'proxmoxcheckbox' : 'checkbox';
        return Ext.apply({ xtype: xtype, uncheckedValue: 0, inputValue: 1 }, config);
    }

    // -----------------------------------------------------------------------
    // The job editor
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.window.JobEdit', {
        extend: 'Ext.window.Window',
        xtype: 'proxmodCronJobEdit',

        width: 620,
        modal: true,
        resizable: true,
        layout: 'fit',

        // 'cluster' or 'node'
        scope: 'node',
        nodename: undefined,
        jobId: undefined,
        isCreate: false,
        // An extension-owned row opens read-only: the fields are still worth
        // seeing, and the enable toggle is still live (§2.1).
        readOnly: false,
        perms: undefined,

        // Everything the form will submit. Collected by walking the fields
        // rather than through getValues(), because an argv is an array and
        // getValues() would flatten it into a string.
        collect: function () {
            var params = {};

            this.down('form').getForm().getFields().each(function (field) {
                // The configured name, not getName(): Ext invents one for a
                // field that was not given one, and an invented name reaching a
                // method that declares additionalProperties => 0 is a 400 for
                // every display field on the form.
                var name = field.initialConfig && field.initialConfig.name;

                if (!name || field.isDisabled() || field.itemId === 'jobId') {
                    return;
                }

                var value = field.proxmodCronValue
                    ? field.proxmodCronValue() : field.getValue();

                if (value === undefined || value === null) {
                    return;
                }
                if (Ext.isArray(value)) {
                    if (value.length) {
                        params[name] = value;
                    }
                    return;
                }
                if (value === true || value === false) {
                    params[name] = value ? 1 : 0;
                    return;
                }
                // An empty comment is a real value — it clears the comment. Any
                // other empty field means "not set", and sending it would be a
                // request to store the empty string.
                if (value === '' && name !== 'comment') {
                    return;
                }
                params[name] = value;
            });

            return params;
        },

        submit: function () {
            var me = this;
            var form = me.down('form').getForm();

            if (!form.isValid()) {
                return;
            }

            var params = me.collect();
            var id = me.isCreate ? me.down('#jobId').getValue() : me.jobId;

            var opts = {
                node: me.nodename,
                waitMsgTarget: me,
                success: function () {
                    me.close();
                    if (me.callback) {
                        me.callback();
                    }
                },
            };

            if (me.isCreate) {
                params.id = id;
                ProxmodCron.api.create(me.scope, params, opts);
            } else {
                // `enabled` is refused by PUT jobs/{id} on purpose, and the
                // editor never offers it: the grid's checkbox and the read-only
                // view both go to the enabled endpoint instead.
                delete params.enabled;
                ProxmodCron.api.update(me.scope, id, params, opts);
            }
        },

        // Swap in the fields for a job type, keeping whatever the user has
        // already typed into fields the new type also has.
        applyType: function (type, values) {
            var me = this;
            var holder = me.down('#typeFields');
            var schema;

            Ext.each(me.typeCatalogue || [], function (entry) {
                if (entry.type === type) {
                    schema = entry;
                }
            });

            holder.removeAll();
            holder.add(typeFields(type, schema, {
                scope: me.scope,
                nodename: me.nodename,
                job: me.job,
            }));

            if (values) {
                Ext.Object.each(values, function (key, value) {
                    var field = holder.down('[name=' + key + ']');
                    if (field) {
                        field.setValue(value);
                    }
                });
            }

            if (me.readOnly) {
                me.lockFields();
            }
        },

        // 'run_on: any' carries two requirements the server refuses without, so
        // the form applies them rather than letting the user discover them from
        // an error dialog: the run record is the only thing that says which node
        // ran the job, and the lease is a write inside /etc/pve.
        //
        // Locked and shown, not hidden: a field that vanished would leave an
        // administrator wondering what the job now runs as.
        applyRunOn: function (value) {
            var me = this;
            var once = value === 'any';
            var note = me.down('#runOnNote');
            var track = me.down('[name=track]');
            var user = me.down('[name=user]');

            if (note) {
                note.setVisible(once);
            }

            if (track) {
                if (once) {
                    track.setValue(1);
                }
                track.setReadOnly(once || !!me.readOnly);
            }

            if (user) {
                if (once) {
                    user.setValue('');
                }
                user.setReadOnly(once || !!me.readOnly);
            }
        },

        lockFields: function () {
            this.down('form').getForm().getFields().each(function (field) {
                // Everything except the one control §2.1 leaves live on an
                // extension-owned job. Locking that too would make the
                // read-only editor useless for the only thing it is for.
                if (field.itemId === 'enabledToggle') {
                    return;
                }
                if (field.setReadOnly) {
                    field.setReadOnly(true);
                }
            });
            var schedule = this.down('proxmodCronSchedule');
            if (schedule) {
                schedule.setReadOnlyState(true);
            }
        },

        loadTypes: function (selected, values) {
            var me = this;

            ProxmodCron.api.types(me.scope, me.nodename, function (data) {
                if (me.destroyed) {
                    return;
                }

                me.typeCatalogue = data || [];

                // §8.3 in the interface: a delegated caller may only create
                // types that declare required_privs, and `command` never
                // declares any. The server refuses either way; offering it
                // would just be a button that always fails.
                var allowed = [];
                var perms = me.perms || {};
                Ext.each(me.typeCatalogue, function (entry) {
                    if (perms.modify || !perms.delegable_types
                        || Ext.Array.contains(perms.delegable_types, entry.type)) {
                        allowed.push({
                            type: entry.type,
                            title: entry.title || entry.type,
                            description: entry.description || '',
                        });
                    }
                });

                var combo = me.down('#typeCombo');
                combo.getStore().loadData(allowed);

                var type = selected;
                if (!type && allowed.length) {
                    type = allowed[0].type;
                }
                if (type) {
                    combo.setValue(type);
                    me.applyType(type, values);
                }
            }, {
                failure: function (response) {
                    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                },
            });
        },

        initComponent: function () {
            var me = this;

            if (me.scope !== 'cluster' && !me.nodename) {
                throw 'no node name specified';
            }

            me.title = me.isCreate
                ? gettext('Create cron job')
                : (me.readOnly ? gettext('Cron job') : gettext('Edit cron job'));

            var items = [];

            items.push({
                xtype: 'textfield',
                itemId: 'jobId',
                name: 'id',
                fieldLabel: gettext('ID'),
                allowBlank: false,
                maxLength: 64,
                regex: /^[a-z0-9][a-z0-9_-]{0,63}$/,
                regexText: gettext('Lower-case letters, digits, - and _; must not'
                    + ' start with - or _'),
                disabled: !me.isCreate,
                hidden: !me.isCreate,
                value: me.jobId,
            });

            if (!me.isCreate) {
                items.push({
                    xtype: 'displayfield',
                    fieldLabel: gettext('ID'),
                    value: enc(me.jobId),
                });
            }

            items.push({
                xtype: 'combobox',
                itemId: 'typeCombo',
                name: 'type',
                fieldLabel: gettext('Type'),
                allowBlank: false,
                editable: false,
                queryMode: 'local',
                displayField: 'title',
                valueField: 'type',
                store: { fields: ['type', 'title', 'description'], data: [] },
                listeners: {
                    change: function (combo, value) {
                        Proxmod.guard('proxmod-cron type change', function () {
                            if (value) {
                                me.applyType(value);
                            }
                        });
                    },
                },
            });

            items.push({ xtype: 'proxmodCronSchedule' });

            items.push({
                xtype: 'textfield',
                name: 'comment',
                fieldLabel: gettext('Comment'),
                maxLength: 512,
                emptyText: gettext('rendered as a comment above the cron line'),
            });

            items.push({
                xtype: 'container',
                itemId: 'typeFields',
                layout: 'anchor',
                defaults: { anchor: '100%', labelWidth: 140 },
                items: [],
            });

            if (me.scope === 'cluster') {
                items.push({
                    xtype: 'proxmodCronArgv',
                    name: 'nodes',
                    fieldLabel: gettext('Nodes (one per line)'),
                    allowBlank: true,
                    emptyText: gettext('empty means every node'),
                });

                // Replication or placement. The two readings of "a cluster job"
                // are far enough apart that the field says what each one does
                // rather than naming the mode and leaving it to the docs.
                items.push({
                    xtype: 'combobox',
                    itemId: 'runOnCombo',
                    name: 'run_on',
                    fieldLabel: gettext('Run on'),
                    editable: false,
                    queryMode: 'local',
                    displayField: 'title',
                    valueField: 'value',
                    value: 'all',
                    store: {
                        fields: ['value', 'title'],
                        data: [
                            { value: 'all',
                                title: gettext('every node it targets, every time') },
                            { value: 'any',
                                title: gettext('exactly one node per scheduled run') },
                        ],
                    },
                    listeners: {
                        change: function (combo, value) {
                            Proxmod.guard('proxmod-cron run_on change', function () {
                                me.applyRunOn(value);
                            });
                        },
                    },
                });

                items.push({
                    xtype: 'displayfield',
                    itemId: 'runOnNote',
                    hideLabel: true,
                    hidden: true,
                    cls: 'proxmod-cron-note',
                    value: enc(gettext('The nodes race for each scheduled run and'
                        + ' one wins it; a node that is down or has lost quorum'
                        + ' simply loses the race, so the job moves on its own.'
                        + ' It needs "Record runs" on, because the run record is'
                        + ' the only thing that says which node ran it, and it'
                        + ' runs as root, because claiming a run is a write'
                        + ' inside /etc/pve that no other user may make.')),
                });
            }

            items.push({
                xtype: 'textfield',
                name: 'user',
                fieldLabel: gettext('Run as user'),
                allowBlank: true,
                maxLength: 32,
                emptyText: 'root',
            });

            items.push(checkbox({
                name: 'track',
                fieldLabel: gettext('Record runs'),
                checked: true,
                boxLabel: gettext('log start, finish and exit status to the journal'),
            }));

            items.push(checkbox({
                name: 'keep_output',
                fieldLabel: gettext('Record output'),
                checked: true,
                boxLabel: gettext('capture stdout and stderr as well'),
            }));

            // Not only in the docs. Turning this on changes who can read what
            // the job prints: the journal is readable by anyone holding
            // Sys.Syslog or a shell on this host, which is a wider audience
            // than the API — and wider than the root mailbox this output used
            // to go to.
            items.push({
                xtype: 'displayfield',
                hideLabel: true,
                cls: 'proxmod-cron-note',
                value: enc(gettext('Anything this job prints is stored in the'
                    + ' system journal, where anyone with Sys.Syslog on this node'
                    + ' or shell access to it can read it. Turn off "Record'
                    + ' output" for a job that prints things that should not'
                    + ' spread.')),
            });

            var buttons = [];

            if (!me.readOnly) {
                buttons.push({
                    text: me.isCreate ? gettext('Create') : gettext('OK'),
                    handler: function () {
                        Proxmod.guard('proxmod-cron job submit', function () {
                            me.submit();
                        });
                    },
                });
            }

            buttons.push({
                text: me.readOnly ? gettext('Close') : gettext('Cancel'),
                handler: function () { me.close(); },
            });

            me.items = [{
                xtype: 'form',
                bodyPadding: 10,
                border: false,
                fieldDefaults: { labelWidth: 140, anchor: '100%' },
                items: items,
            }];

            me.buttons = buttons;

            me.callParent();

            // A read-only editor still carries the one control §2.1 leaves live
            // on an extension-owned job. It sits above the form so it reads as
            // the thing you came here to change.
            if (me.readOnly && me.job && me.job.can_toggle) {
                me.down('form').insert(0, checkbox({
                    itemId: 'enabledToggle',
                    fieldLabel: gettext('Enabled'),
                    checked: !!me.job.enabled,
                    boxLabel: gettext('this is the one change permitted here'),
                    listeners: {
                        change: function (field, value) {
                            Proxmod.guard('proxmod-cron enable toggle', function () {
                                ProxmodCron.api.setEnabled(me.scope, me.jobId, value, {
                                    node: me.nodename,
                                    waitMsgTarget: me,
                                    success: function () {
                                        if (me.callback) { me.callback(); }
                                    },
                                    failure: function (response) {
                                        field.suspendEvents();
                                        field.setValue(!value);
                                        field.resumeEvents();
                                        Ext.Msg.alert(gettext('Error'),
                                            response.htmlStatus);
                                    },
                                });
                            });
                        },
                    },
                }));
            }

            if (me.readOnly && me.job && !me.job.can_toggle) {
                me.down('form').insert(0, {
                    xtype: 'displayfield',
                    hideLabel: true,
                    cls: 'proxmod-cron-note',
                    value: enc(me.job.managed_in === 'cluster'
                        ? gettext('This job is defined in the cluster store. Change'
                            + ' it on the Cron tab of the datacenter.')
                        : gettext('This job is read-only for you.')),
                });
            }

            var values = me.job ? Ext.apply({}, me.job) : undefined;

            if (values) {
                me.down('form').getForm().setValues({
                    comment: values.comment || '',
                    user: values.user || '',
                    track: values.track ? 1 : 0,
                    keep_output: values.keep_output ? 1 : 0,
                });
                me.down('proxmodCronSchedule').setValue(values.schedule);
                if (me.scope === 'cluster') {
                    me.down('[name=nodes]').setValue(values.nodes || []);
                    me.down('#runOnCombo').setValue(values.run_on || 'all');
                }
            }

            if (me.scope === 'cluster') {
                me.applyRunOn(me.down('#runOnCombo').getValue());
            }

            me.loadTypes(values ? values.type : undefined, values);

            if (!me.isCreate) {
                me.down('#typeCombo').setReadOnly(true);
            }

            if (me.readOnly) {
                me.lockFields();
            }
        },
    });

    // The documented entry point for another extension: open the editor on a
    // type of its own without knowing anything about these classes.
    ProxmodCron.openEditor = function (config) {
        var opts = config || {};
        var win = Ext.create('ProxmodCron.window.JobEdit', {
            scope: opts.scope || 'node',
            nodename: opts.node,
            isCreate: opts.id ? false : true,
            jobId: opts.id,
            job: opts.job,
            perms: opts.perms,
            callback: opts.callback,
        });
        win.show();
        if (opts.type) {
            win.down('#typeCombo').setValue(opts.type);
        }
        return win;
    };

    // -----------------------------------------------------------------------
    // The run log
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.panel.RunLog', {
        extend: 'Ext.panel.Panel',
        xtype: 'proxmodCronRunLog',

        nodename: undefined,
        runid: undefined,

        scrollable: true,
        bodyPadding: 8,
        bodyCls: 'proxmod-cron-log',

        cursor: undefined,
        finished: false,
        lineCount: 0,

        message: function (text, cls) {
            this.update('<div class="' + (cls || 'proxmod-cron-note') + '">'
                + enc(text) + '</div>');
        },

        append: function (lines) {
            var me = this;
            var html = [];

            Ext.each(lines, function (line) {
                // The wrapper numbers every line it sent; a hole means journald
                // dropped what was between, usually to its own rate limit. Shown
                // as a rule, because the alternative is a log that silently
                // reads as shorter than the run actually was.
                if (line.gap) {
                    html.push('<div class="proxmod-cron-log-gap">'
                        + enc(Ext.String.format(
                            gettext('{0} lines missing from the journal'),
                            line.gap))
                        + '</div>');
                }

                var cls = line.stream === 'stderr'
                    ? 'proxmod-cron-log-err' : 'proxmod-cron-log-out';
                // The most attacker-influenced text in the extension: arbitrary
                // bytes a root command chose, including remote data a backup or
                // sync tool echoed back. Encoded here, and the server has
                // already stripped control characters.
                html.push('<div class="' + cls + '">' + enc(line.text) + '</div>');
            });

            if (!html.length) {
                return;
            }

            me.lineCount += lines.length;

            var body = me.body;
            if (me.lineCount === lines.length) {
                body.setHtml(html.join(''));
            } else {
                body.insertHtml('beforeEnd', html.join(''));
            }

            if (me.followEnd) {
                me.scrollBy(0, 100000, false);
            }
        },

        jumpToEnd: function () {
            this.scrollBy(0, 100000, false);
        },

        reload: function () {
            var me = this;
            me.cursor = undefined;
            me.lineCount = 0;
            me.finished = false;
            me.body.setHtml('');
            me.fetch();
        },

        fetch: function () {
            var me = this;

            if (me.destroyed || me.loading) {
                return;
            }
            me.loading = true;

            ProxmodCron.api.log(me.nodename, me.runid, {
                params: me.cursor ? { cursor: me.cursor, limit: 500 } : { limit: 500 },
                success: function (response) {
                    me.loading = false;
                    if (me.destroyed) {
                        return;
                    }

                    var data = response.result.data || {};

                    me.append(data.lines || []);

                    if (data.cursor) {
                        me.cursor = data.cursor;
                    }

                    if (!me.lineCount && data.done) {
                        me.emptySoFar();
                    }

                    // Poll only while the run has no finish record. Once it has
                    // one and we have caught up with the journal, there is
                    // nothing more coming.
                    if (data.done) {
                        me.checkFinished();
                    } else {
                        me.schedule();
                    }
                },
                failure: function (response) {
                    me.loading = false;
                    if (me.destroyed) {
                        return;
                    }
                    me.explain(response);
                },
            });
        },

        // The two expected failures are states, not errors. A blank box here
        // reads as a bug in this extension, which is the one thing it is not.
        explain: function (response) {
            var status = response.status || (response.result || {}).status;
            var text = response.htmlStatus || (response.result || {}).message || '';

            if (status === 403 || /403/.test(String(text))) {
                this.message(gettext('Reading job output requires Sys.Syslog on'
                    + ' this node. The run history above needs only Sys.Audit,'
                    + ' which is why it is still visible.'),
                    'proxmod-cron-warning');
                return;
            }

            if (/no run /.test(String(text))) {
                this.message(gettext('This run\'s output is no longer in the'
                    + ' journal. journald applies the host\'s own retention'
                    + ' settings to these records; nothing about running jobs'
                    + ' depends on the history still being there.'),
                    'proxmod-cron-warning');
                return;
            }

            this.message(Ext.String.format(gettext('Could not read this run: {0}'),
                Ext.util.Format.stripTags(String(text))), 'proxmod-cron-error');
        },

        emptySoFar: function () {
            // A run with no output lines is the ordinary case for a job that
            // succeeded quietly, and for one with keep_output off. Both read
            // the same from here; the retention case is not this one, because
            // journald having dropped the run entirely makes the lookup fail
            // rather than come back empty.
            this.message(gettext('No output was recorded for this run.'));
        },

        checkFinished: function () {
            var me = this;

            if (me.finished) {
                return;
            }

            ProxmodCron.api.getRun(me.nodename, me.runid, {
                success: function (response) {
                    if (me.destroyed) {
                        return;
                    }
                    var run = response.result.data || {};
                    if (run.finished) {
                        me.finished = true;
                    } else {
                        me.schedule();
                    }
                },
                failure: function () {
                    // A run we cannot re-read is a run we stop polling for.
                    me.finished = true;
                },
            });
        },

        schedule: function () {
            var me = this;
            if (me.destroyed || me.finished) {
                return;
            }
            me.pollTask.delay(2000);
        },

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }
            if (!me.runid) {
                throw 'no run id specified';
            }

            me.followEnd = true;

            me.tbar = [
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        Proxmod.guard('proxmod-cron log reload', function () {
                            me.reload();
                        });
                    },
                },
                {
                    text: gettext('Jump to end'),
                    iconCls: 'fa fa-angle-double-down',
                    handler: function () {
                        Proxmod.guard('proxmod-cron log jump', function () {
                            me.jumpToEnd();
                        });
                    },
                },
                '->',
                {
                    xtype: 'displayfield',
                    value: enc(me.runid),
                    cls: 'proxmod-cron-muted',
                },
            ];

            me.pollTask = new Ext.util.DelayedTask(function () {
                Proxmod.guard('proxmod-cron log poll', function () { me.fetch(); });
            });

            me.callParent();

            me.on('destroy', function () { me.pollTask.cancel(); });
            me.on('afterrender', function () {
                Proxmod.guard('proxmod-cron log load', function () { me.fetch(); });
            });
        },
    });

    ProxmodCron.openRunLog = function (config) {
        var opts = config || {};

        var win = Ext.create('Ext.window.Window', {
            title: Ext.String.format(gettext('Run {0}'), opts.run),
            modal: false,
            width: 900,
            height: 600,
            layout: 'fit',
            items: [{
                xtype: 'proxmodCronRunLog',
                nodename: opts.node,
                runid: opts.run,
            }],
        });

        win.show();
        return win;
    };

    // -----------------------------------------------------------------------
    // The run history
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.grid.RunGrid', {
        extend: 'Ext.grid.GridPanel',
        xtype: 'proxmodCronRuns',

        nodename: undefined,
        jobId: undefined,
        // Whether the caller may read output. Only decides whether the Log
        // button is offered; the server checks it regardless.
        canReadOutput: true,

        setJob: function (id) {
            var me = this;
            me.jobId = id;
            me.reload();
        },

        reload: function () {
            var me = this;

            if (!me.jobId) {
                me.getStore().loadData([]);
                return;
            }

            ProxmodCron.api.runs(me.nodename, me.jobId, {
                params: { since: me.since || '-7d', limit: 200 },
                waitMsgTarget: me,
                success: function (response) {
                    if (!me.destroyed) {
                        me.getStore().loadData(response.result.data || []);
                    }
                },
                failure: function (response) {
                    if (!me.destroyed) {
                        me.getStore().loadData([]);
                        Proxmod.log.warn('proxmod-cron: run history failed',
                            response.htmlStatus);
                    }
                },
            });
        },

        openLog: function (record) {
            if (!record) {
                return;
            }
            ProxmodCron.openRunLog({ node: this.nodename, run: record.data.run });
        },

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.store = Ext.create('Ext.data.Store', {
                fields: ['run', 'job', 'scope', 'type', 'started', 'finished',
                    'exit', 'signal', 'duration_ms', 'lines', 'truncated',
                    'state', 'cursor', 'skipped', 'message'],
                data: [],
            });

            var logButton = {
                xtype: 'button',
                itemId: 'logButton',
                text: gettext('Log'),
                iconCls: 'fa fa-file-text-o',
                disabled: true,
                handler: function () {
                    Proxmod.guard('proxmod-cron open log', function () {
                        me.openLog(me.getSelection()[0]);
                    });
                },
            };

            me.tbar = [
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        Proxmod.guard('proxmod-cron runs reload', function () {
                            me.reload();
                        });
                    },
                },
                logButton,
                '->',
                {
                    xtype: 'combobox',
                    itemId: 'since',
                    width: 160,
                    editable: false,
                    queryMode: 'local',
                    displayField: 'text',
                    valueField: 'value',
                    value: '-7d',
                    store: {
                        fields: ['value', 'text'],
                        data: [
                            { value: '-1h', text: gettext('last hour') },
                            { value: '-1d', text: gettext('last day') },
                            { value: '-7d', text: gettext('last week') },
                            { value: '-30d', text: gettext('last 30 days') },
                        ],
                    },
                    listeners: {
                        change: function (field, value) {
                            Proxmod.guard('proxmod-cron runs window', function () {
                                me.since = value;
                                me.reload();
                            });
                        },
                    },
                },
            ];

            me.columns = [
                {
                    header: gettext('Started'),
                    dataIndex: 'started',
                    width: 160,
                    renderer: function (v) { return enc(stamp(v)); },
                },
                {
                    header: gettext('Duration'),
                    dataIndex: 'duration_ms',
                    width: 100,
                    renderer: function (v) { return enc(duration(v)); },
                },
                {
                    header: gettext('Result'),
                    dataIndex: 'state',
                    width: 160,
                    renderer: function (value, meta, record) {
                        var data = record.data;
                        if (data.skipped) {
                            meta.tdAttr = qtip(enc(data.message || ''));
                            return '<span class="proxmod-cron-warning">'
                                + enc(gettext('skipped (still running)')) + '</span>';
                        }
                        if (value === 'ok') {
                            return '<span class="proxmod-cron-ok">'
                                + enc(gettext('OK')) + '</span>';
                        }
                        if (value === 'killed') {
                            return '<span class="proxmod-cron-error">'
                                + enc(Ext.String.format(gettext('killed (signal {0})'),
                                    data.signal)) + '</span>';
                        }
                        if (value === 'failed') {
                            return '<span class="proxmod-cron-error">'
                                + enc(Ext.String.format(gettext('exit {0}'), data.exit))
                                + '</span>';
                        }
                        if (value === 'running') {
                            return '<span class="proxmod-cron-muted">'
                                + enc(gettext('running')) + '</span>';
                        }
                        // A start with no finish and no lock: the node most
                        // likely lost power mid-job. Saying 'unknown' is the
                        // honest answer; showing it as still running forever is
                        // not.
                        return '<span class="proxmod-cron-warning">'
                            + enc(gettext('unknown')) + '</span>';
                    },
                },
                {
                    header: gettext('Output'),
                    dataIndex: 'lines',
                    width: 110,
                    renderer: function (value, meta, record) {
                        var text = String(value || 0);
                        if (record.data.truncated) {
                            text += ' ' + gettext('(truncated)');
                        }
                        return enc(text);
                    },
                },
                {
                    header: gettext('Run'),
                    dataIndex: 'run',
                    flex: 1,
                    renderer: function (v) { return enc(v); },
                },
            ];

            me.callParent();

            me.on('selectionchange', function (grid, selection) {
                Proxmod.guard('proxmod-cron run selection', function () {
                    var button = me.down('#logButton');
                    var record = selection[0];

                    if (!record) {
                        button.setDisabled(true);
                        return;
                    }

                    button.setDisabled(!me.canReadOutput);
                    button.setTooltip(me.canReadOutput ? undefined
                        : gettext('Reading job output requires Sys.Syslog on this node'));
                });
            });

            me.on('itemdblclick', function (grid, record) {
                Proxmod.guard('proxmod-cron open log', function () {
                    if (me.canReadOutput) {
                        me.openLog(record);
                    }
                });
            });
        },
    });

    // -----------------------------------------------------------------------
    // The job grid — the shared one, configured with a scope
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.grid.JobGrid', {
        extend: 'Ext.grid.GridPanel',
        xtype: 'proxmodCronJobGrid',

        // 'cluster' or 'node'
        scope: 'cluster',
        nodename: undefined,

        perms: undefined,

        reload: function () {
            var me = this;

            me.getStore().load();

            // Quorum is the thing most likely to have changed between two
            // presses of Reload, and the one that decides whether any of these
            // rows will run at all.
            if (me.scope === 'cluster' && me.down('#quorumBanner')) {
                ProxmodCron.api.membership(function (data) {
                    if (!me.destroyed) {
                        me.showMembership(data);
                    }
                }, {
                    // Silent: a cluster tab whose job list loaded is still
                    // useful, and the banner standing as it was beats an error
                    // dialog over a request nobody asked for.
                    failure: function () { /* the banner stands as it was */ },
                });
            }
        },

        selected: function () {
            return this.getSelection()[0];
        },

        // Every button's state comes from the row's own flags, which the server
        // computed. Disabled, never hidden, with a tooltip naming the reason —
        // a user who cannot find a feature files a support ticket; a user who
        // can see why it is greyed out asks for the right role.
        updateButtons: function () {
            var me = this;
            var record = me.selected();
            var data = record ? record.data : undefined;
            var perms = me.perms || {};

            var addButton = me.down('#addButton');
            if (addButton) {
                addButton.setDisabled(!perms.modify);
                addButton.setTooltip(perms.modify ? undefined
                    : Ext.String.format(gettext('Requires Sys.Modify on {0}'),
                        me.aclPath()));
            }

            Ext.each([
                ['#editButton', 'can_edit', gettext('This job cannot be edited here')],
                ['#removeButton', 'can_delete', gettext('This job cannot be removed here')],
                ['#runButton', 'can_run', gettext('Running a job now requires'
                    + ' Sys.Modify, or the privileges its type declares')],
            ], function (spec) {
                var button = me.down(spec[0]);
                if (!button) {
                    return;
                }
                if (!data) {
                    button.setDisabled(true);
                    button.setTooltip(undefined);
                    return;
                }
                var allowed = !!data[spec[1]];
                button.setDisabled(!allowed);
                button.setTooltip(allowed ? undefined : me.refusalFor(data, spec[2]));
            });
        },

        aclPath: function () {
            return this.scope === 'cluster' ? '/' : '/nodes/' + this.nodename;
        },

        // Why a button is dead, in the words §2.1 uses. The origin half is the
        // interesting half — a missing privilege sends you to the ACL editor, a
        // managed job sends you to the extension that owns it, and those are
        // different errands.
        refusalFor: function (data, fallback) {
            if (data.managed_in === 'cluster') {
                return gettext('This job is defined in the cluster store. Change it'
                    + ' on the datacenter\'s Cron tab.');
            }
            if (data.origin === 'extension' && data.orphaned) {
                return Ext.String.format(gettext('Created by {0}, which is no longer'
                    + ' installed. You can enable, disable or remove it.'),
                    data.owner || gettext('an extension'));
            }
            if (data.origin === 'extension') {
                return Ext.String.format(gettext('Managed by {0}. You can enable or'
                    + ' disable it here; to change or remove it, use that extension.'),
                    data.owner || gettext('an extension'));
            }
            if (!data.can_modify) {
                return Ext.String.format(gettext('Requires Sys.Modify on {0}'),
                    this.aclPath());
            }
            return fallback;
        },

        setEnabled: function (record, checked) {
            var me = this;

            ProxmodCron.api.setEnabled(me.scope, record.data.id, checked, {
                node: me.nodename,
                waitMsgTarget: me,
                success: function () {
                    // Reload rather than trust the checkbox: the next run and
                    // the rendered line both change with it.
                    me.reload();
                },
                failure: function (response) {
                    if (me.destroyed) {
                        return;
                    }
                    // Put the checkbox back. A grid that disagrees with the
                    // server about whether a root job is running is worse than
                    // an error dialog.
                    record.set('enabled', !checked);
                    record.commit();
                    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                },
            });
        },

        openEditor: function (record) {
            var me = this;
            var data = record ? record.data : undefined;

            var win = Ext.create('ProxmodCron.window.JobEdit', {
                scope: me.scope,
                nodename: me.nodename,
                perms: me.perms,
                isCreate: !data,
                jobId: data ? data.id : undefined,
                job: data,
                // An extension-owned row opens read-only rather than not at
                // all: the schedule and the command are still worth seeing.
                readOnly: data ? !data.can_edit : false,
                callback: function () { me.reload(); },
            });

            win.show();
        },

        removeJob: function (record) {
            var me = this;
            var id = record.data.id;

            Ext.Msg.confirm(gettext('Confirm'),
                Ext.String.format(gettext('Remove cron job {0}?'), enc(id)),
                function (answer) {
                    if (answer !== 'yes') {
                        return;
                    }
                    Proxmod.guard('proxmod-cron remove', function () {
                        ProxmodCron.api.remove(me.scope, id, {
                            node: me.nodename,
                            waitMsgTarget: me,
                            success: function () { me.reload(); },
                        });
                    });
                });
        },

        runJob: function (record) {
            var me = this;

            ProxmodCron.api.run(me.nodename, record.data.id, {
                waitMsgTarget: me,
                success: function (response) {
                    var upid = response.result.data;

                    me.fireEvent('proxmodcronrun', me, record.data.id, upid);

                    // The standard task viewer if this host has it; the UPID
                    // otherwise, because it is what the Tasks panel needs and
                    // swallowing it would leave the user with nothing.
                    if (Ext.ClassManager.get('Proxmox.window.TaskViewer')) {
                        Ext.create('Proxmox.window.TaskViewer', { upid: upid }).show();
                    } else {
                        Ext.Msg.alert(gettext('Task started'), enc(upid));
                    }
                },
            });
        },

        applyPermissions: function (perms) {
            this.perms = perms;
            this.updateButtons();
        },

        // A cluster job does not run on a node that cannot confirm it is still
        // in the cluster. Without this the datacenter tab would show a schedule
        // that is, on this node, not happening — and the only other place that
        // says so is `proxmod-cronctl doctor` on a shell.
        //
        // "this node" is the node serving the request, which for a datacenter
        // tab is whichever one the browser is talking to. Said in the text,
        // because a cluster-wide banner is what it would otherwise be read as.
        showMembership: function (data) {
            var me = this;
            var banner = me.down('#quorumBanner');

            if (!banner) {
                return;
            }

            if (!data || data.standalone) {
                banner.setHidden(true);
                return;
            }

            var node = data.node || gettext('this node');
            var text;
            var cls;

            if (!data.quorate && data.known) {
                cls = 'proxmod-cron-error';
                text = Ext.String.format(gettext('{0} is not quorate. Every'
                    + ' cluster job stands down there until quorum returns;'
                    + ' node-scoped jobs are unaffected.'), node);
            } else if (!data.known) {
                cls = 'proxmod-cron-warning';
                text = Ext.String.format(gettext('The cluster state cannot be'
                    + ' determined on {0}, so every cluster job stands down'
                    + ' there: {1}'), node, data.reason || gettext('no reason given'));
            } else {
                var offline = [];
                Ext.each(data.nodes || [], function (entry) {
                    if (!entry.online) {
                        offline.push(entry.node);
                    }
                });

                if (!offline.length) {
                    banner.setHidden(true);
                    return;
                }

                cls = 'proxmod-cron-warning';
                text = Ext.String.format(gettext('Offline: {0}. Jobs targeting'
                    + ' only those nodes are not running; jobs set to one node'
                    + ' per run will be claimed by a node that is up.'),
                    offline.join(', '));
            }

            banner.update('<div class="' + cls + '">' + enc(text) + '</div>');
            banner.setHidden(false);
        },

        initComponent: function () {
            var me = this;

            if (me.scope !== 'cluster' && !me.nodename) {
                throw 'no node name specified';
            }

            me.store = Ext.create('Ext.data.Store', {
                fields: ['id', 'scope', 'type', 'enabled', 'schedule', 'next_run',
                    'user', 'comment', 'command', 'nodes', 'run_on', 'last_holder',
                    'origin', 'owner',
                    'orphaned', 'managed_in', 'track', 'keep_output',
                    'can_edit', 'can_delete', 'can_toggle', 'can_run', 'can_modify',
                    'last_run', 'schedule_error', 'type_available'],
                proxy: {
                    type: 'proxmox',
                    url: ProxmodCron.api.storeUrl('jobs', me.nodename),
                },
                sorters: 'id',
            });

            if (Proxmox.Utils.monStoreErrors) {
                Proxmox.Utils.monStoreErrors(me, me.store, true);
            }

            me.tbar = [
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        Proxmod.guard('proxmod-cron reload', function () { me.reload(); });
                    },
                },
                {
                    itemId: 'addButton',
                    text: gettext('Add'),
                    iconCls: 'fa fa-plus',
                    disabled: true,
                    handler: function () {
                        Proxmod.guard('proxmod-cron add', function () {
                            me.openEditor();
                        });
                    },
                },
                {
                    itemId: 'editButton',
                    text: gettext('Edit'),
                    iconCls: 'fa fa-pencil',
                    disabled: true,
                    handler: function () {
                        Proxmod.guard('proxmod-cron edit', function () {
                            me.openEditor(me.selected());
                        });
                    },
                },
                {
                    itemId: 'removeButton',
                    text: gettext('Remove'),
                    iconCls: 'fa fa-trash-o',
                    disabled: true,
                    handler: function () {
                        Proxmod.guard('proxmod-cron remove', function () {
                            me.removeJob(me.selected());
                        });
                    },
                },
            ];

            if (me.scope !== 'cluster') {
                me.tbar.push({
                    itemId: 'runButton',
                    text: gettext('Run now'),
                    iconCls: 'fa fa-play',
                    disabled: true,
                    handler: function () {
                        Proxmod.guard('proxmod-cron run now', function () {
                            me.runJob(me.selected());
                        });
                    },
                });
            }

            var columns = [
                {
                    xtype: 'checkcolumn',
                    header: gettext('Enabled'),
                    dataIndex: 'enabled',
                    width: 80,
                    stopSelection: true,
                    listeners: {
                        // The one control that is live on every row the caller
                        // may modify, whatever the job's origin: an
                        // administrator must always be able to stop a job
                        // without uninstalling what created it.
                        beforecheckchange: function (col, index, checked, record) {
                            if (record && record.data.can_toggle) {
                                return true;
                            }
                            Ext.Msg.alert(gettext('Not permitted'),
                                enc(me.refusalFor(record ? record.data : {},
                                    gettext('This job cannot be switched here'))));
                            return false;
                        },
                        checkchange: function (col, index, checked, record) {
                            Proxmod.guard('proxmod-cron toggle', function () {
                                me.setEnabled(record, checked);
                            });
                        },
                    },
                },
                {
                    header: gettext('ID'),
                    dataIndex: 'id',
                    width: 180,
                    renderer: function (value, meta, record) {
                        if (record.data.comment) {
                            meta.tdAttr = qtip(enc(record.data.comment));
                        }
                        return enc(value);
                    },
                },
                {
                    header: gettext('Type'),
                    dataIndex: 'type',
                    width: 120,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Source'),
                    dataIndex: 'origin',
                    width: 140,
                    renderer: renderSource,
                },
                {
                    header: gettext('Schedule'),
                    dataIndex: 'schedule',
                    width: 130,
                    renderer: renderSchedule,
                },
                {
                    header: gettext('Next run'),
                    dataIndex: 'next_run',
                    width: 150,
                    renderer: renderNextRun,
                },
                {
                    header: gettext('User'),
                    dataIndex: 'user',
                    width: 90,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Command'),
                    dataIndex: 'command',
                    flex: 1,
                    renderer: renderCommand,
                },
            ];

            if (me.scope === 'cluster') {
                columns.push({
                    header: gettext('Nodes'),
                    dataIndex: 'nodes',
                    width: 160,
                    renderer: renderNodes,
                });

                columns.push({
                    header: gettext('Run on'),
                    dataIndex: 'run_on',
                    width: 150,
                    renderer: renderRunOn,
                });

                // Placement, not history — which is why it is here and the last
                // result is not. It comes from /etc/pve, so every node gives the
                // same answer, and that answer is about the cluster rather than
                // about whichever node served the request.
                columns.push({
                    header: gettext('Last claimed by'),
                    dataIndex: 'last_holder',
                    width: 150,
                    renderer: renderLastHolder,
                });

                // No last-result column here, deliberately. Run history is
                // node-scoped because journald is, and a cluster-wide column
                // would mean one request per row per node — or a number that
                // silently means "on whichever node answered". The node's Cron
                // tab has the real one.
            } else {
                columns.push({
                    header: gettext('Managed in'),
                    dataIndex: 'managed_in',
                    width: 110,
                    renderer: function (value) {
                        return enc(value === 'cluster'
                            ? gettext('cluster') : gettext('this node'));
                    },
                });

                columns.push({
                    header: gettext('Last result'),
                    dataIndex: 'last_run',
                    width: 150,
                    renderer: renderLastResult,
                });
            }

            me.columns = columns;

            me.callParent();

            me.on('selectionchange', function () {
                Proxmod.guard('proxmod-cron selection', function () {
                    me.updateButtons();
                });
            });

            me.on('itemdblclick', function (grid, record) {
                Proxmod.guard('proxmod-cron open', function () {
                    me.openEditor(record);
                });
            });

            me.on('afterrender', function () {
                Proxmod.guard('proxmod-cron init', function () {
                    if (me.scope === 'cluster') {
                        me.addDocked({
                            xtype: 'component',
                            itemId: 'quorumBanner',
                            dock: 'top',
                            hidden: true,
                            padding: '4 8',
                        });
                    }

                    // The instant, no-round-trip answer first, so the toolbar is
                    // not wrong for the length of a request; then the accurate
                    // one, which is the only one anything is decided from.
                    var caps = Ext.state.Manager.get('GuiCap');
                    var key = me.scope === 'cluster' ? 'dc' : 'nodes';
                    me.perms = {
                        modify: !!(caps && caps[key] && caps[key]['Sys.Modify']),
                    };
                    me.updateButtons();

                    ProxmodCron.api.permissions(me.scope, me.nodename, function (data) {
                        if (!me.destroyed && data) {
                            me.applyPermissions(data);
                            me.fireEvent('proxmodcronperms', me, data);
                        }
                    }, {
                        failure: function () { /* the coarse answer stands */ },
                    });

                    me.reload();
                });
            });
        },
    });

    // -----------------------------------------------------------------------
    // The inventory — everything scheduled on this host, read-only
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.grid.Inventory', {
        extend: 'Ext.grid.GridPanel',
        xtype: 'proxmodCronInventory',

        nodename: undefined,

        reload: function () {
            this.getStore().load();
        },

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.store = Ext.create('Ext.data.Store', {
                fields: ['source', 'path', 'line', 'user', 'schedule', 'command',
                    'owner', 'next_run', 'note', 'schedule_error'],
                proxy: {
                    type: 'proxmox',
                    url: ProxmodCron.api.storeUrl('inventory', me.nodename),
                },
                groupField: 'path',
                sorters: [{ property: 'path' }, { property: 'line' }],
            });

            if (Proxmox.Utils.monStoreErrors) {
                Proxmox.Utils.monStoreErrors(me, me.store, true);
            }

            me.features = [{
                ftype: 'grouping',
                groupHeaderTpl: '{name} ({rows.length})',
            }];

            me.tbar = [
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        Proxmod.guard('proxmod-cron inventory reload', function () {
                            me.reload();
                        });
                    },
                },
                '->',
                {
                    xtype: 'displayfield',
                    cls: 'proxmod-cron-muted',
                    // Read-only in every direction, including enable/disable.
                    // Commenting out a line in a file another package owns
                    // would be undone by that package's next upgrade, and it
                    // would break the property that makes this extension safe
                    // to install.
                    value: enc(gettext('Read-only. Entries this extension does not'
                        + ' own are never modified, including to disable them.')),
                },
            ];

            me.columns = [
                {
                    header: gettext('Owner'),
                    dataIndex: 'owner',
                    width: 130,
                    renderer: function (value) {
                        if (value === 'proxmod-cron') {
                            return '<span class="proxmod-cron-ok">'
                                + enc(gettext('proxmod-cron')) + '</span>';
                        }
                        return enc(value);
                    },
                },
                {
                    header: gettext('Source'),
                    dataIndex: 'source',
                    width: 100,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Line'),
                    dataIndex: 'line',
                    width: 70,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Schedule'),
                    dataIndex: 'schedule',
                    width: 130,
                    renderer: renderSchedule,
                },
                {
                    header: gettext('User'),
                    dataIndex: 'user',
                    width: 90,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Next run'),
                    dataIndex: 'next_run',
                    width: 150,
                    renderer: function (v) { return v ? enc(stamp(v)) : '-'; },
                },
                {
                    header: gettext('Command'),
                    dataIndex: 'command',
                    flex: 1,
                    renderer: function (value, meta, record) {
                        var tip = enc(value);
                        if (record.data.note) {
                            tip += '<br>' + enc(record.data.note);
                        }
                        meta.tdAttr = qtip(tip);
                        if (record.data.note) {
                            return '<span class="proxmod-cron-warning">'
                                + enc(value) + '</span>';
                        }
                        return enc(value);
                    },
                },
            ];

            me.callParent();

            me.on('afterrender', function () {
                Proxmod.guard('proxmod-cron inventory load', function () {
                    me.reload();
                });
            });
        },
    });

    // -----------------------------------------------------------------------
    // The node's proxmod-cron journal — runs and management actions, one
    // timeline. This is §8.6's payoff made visible: "who changed this job, and
    // how has it run since" is one view because both sinks share one field.
    //
    // Not Proxmox.panel.JournalView: that widget sends lastentries/startcursor/
    // endcursor and expects a bare array whose first and last elements are
    // cursors. Our endpoint declares additionalProperties => 0 and returns an
    // object, so it would 400 on the widget's first request. §10 kept this
    // panel as the fallback for exactly that reason.
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.grid.Journal', {
        extend: 'Ext.grid.GridPanel',
        xtype: 'proxmodCronJournal',

        nodename: undefined,

        reload: function () {
            var me = this;

            ProxmodCron.api.journal(me.nodename, {
                params: { since: me.since || '-1d', limit: 500 },
                waitMsgTarget: me,
                success: function (response) {
                    if (!me.destroyed) {
                        var data = response.result.data || {};
                        me.getStore().loadData(data.entries || []);
                    }
                },
            });
        },

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.store = Ext.create('Ext.data.Store', {
                fields: ['time', 'priority', 'event', 'job', 'scope', 'run',
                    'actor', 'via', 'user', 'message'],
                data: [],
            });

            me.tbar = [
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        Proxmod.guard('proxmod-cron journal reload', function () {
                            me.reload();
                        });
                    },
                },
                '->',
                {
                    xtype: 'combobox',
                    width: 160,
                    editable: false,
                    queryMode: 'local',
                    displayField: 'text',
                    valueField: 'value',
                    value: '-1d',
                    store: {
                        fields: ['value', 'text'],
                        data: [
                            { value: '-1h', text: gettext('last hour') },
                            { value: '-1d', text: gettext('last day') },
                            { value: '-7d', text: gettext('last week') },
                            { value: '-30d', text: gettext('last 30 days') },
                        ],
                    },
                    listeners: {
                        change: function (field, value) {
                            Proxmod.guard('proxmod-cron journal window', function () {
                                me.since = value;
                                me.reload();
                            });
                        },
                    },
                },
            ];

            me.columns = [
                {
                    header: gettext('Time'),
                    dataIndex: 'time',
                    width: 160,
                    renderer: function (v) { return enc(stamp(v)); },
                },
                {
                    header: gettext('Event'),
                    dataIndex: 'event',
                    width: 90,
                    renderer: function (v) { return enc(v); },
                },
                {
                    header: gettext('Job'),
                    dataIndex: 'job',
                    width: 160,
                    renderer: function (v) { return enc(v); },
                },
                {
                    // Actor, not user: a change an extension made has no PVE
                    // user, and binding this to `user` left the column blank
                    // for every one of them.
                    header: gettext('Actor'),
                    dataIndex: 'actor',
                    width: 140,
                    renderer: function (value, meta, record) {
                        var via = record.data.via;
                        if (via) {
                            meta.tdAttr = qtip(enc(gettext('via') + ' ' + via));
                        }
                        return enc(value);
                    },
                },
                {
                    header: gettext('Message'),
                    dataIndex: 'message',
                    flex: 1,
                    renderer: function (value, meta, record) {
                        meta.tdAttr = qtip(enc(value));
                        // PRIORITY 4 is a stderr line, 3 a non-zero exit or a
                        // signal (§5.3).
                        var priority = parseInt(record.data.priority, 10);
                        if (priority <= 3) {
                            return '<span class="proxmod-cron-error">'
                                + enc(value) + '</span>';
                        }
                        if (priority === 4) {
                            return '<span class="proxmod-cron-warning">'
                                + enc(value) + '</span>';
                        }
                        return enc(value);
                    },
                },
            ];

            me.callParent();

            me.on('afterrender', function () {
                Proxmod.guard('proxmod-cron journal load', function () {
                    me.reload();
                });
            });
        },
    });

    // -----------------------------------------------------------------------
    // The node tab
    // -----------------------------------------------------------------------

    Ext.define('ProxmodCron.panel.Node', {
        extend: 'Ext.tab.Panel',
        xtype: 'proxmodCronNodePanel',

        nodename: undefined,

        // The tabs whose whole content needs a privilege are added when the
        // answer arrives rather than rendered empty: a 403 in a grid reads as a
        // bug in this extension.
        applyPermissions: function (perms) {
            var me = this;

            if (me.destroyed) {
                return;
            }

            me.down('proxmodCronRuns').canReadOutput = !!(perms.syslog
                || (perms.delegable_types && perms.delegable_types.length));

            if (perms.audit && !me.down('proxmodCronInventory')) {
                me.add({
                    title: gettext('Inventory'),
                    xtype: 'proxmodCronInventory',
                    iconCls: 'fa fa-list',
                    nodename: me.nodename,
                });
            }

            if (perms.syslog && !me.down('proxmodCronJournal')) {
                me.add({
                    title: gettext('Log'),
                    xtype: 'proxmodCronJournal',
                    iconCls: 'fa fa-file-text-o',
                    nodename: me.nodename,
                });
            }
        },

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.items = [{
                title: gettext('Jobs'),
                iconCls: 'fa fa-clock-o',
                xtype: 'panel',
                layout: 'border',
                border: false,
                items: [
                    {
                        xtype: 'proxmodCronJobGrid',
                        region: 'center',
                        border: false,
                        scope: 'node',
                        nodename: me.nodename,
                    },
                    {
                        // Selecting a job answers "is this working?" without a
                        // second click, which is the question the grid's status
                        // column raises and cannot answer on its own.
                        xtype: 'proxmodCronRuns',
                        region: 'south',
                        title: gettext('Runs'),
                        collapsible: true,
                        split: true,
                        height: 260,
                        border: false,
                        nodename: me.nodename,
                    },
                ],
            }];

            me.callParent();

            var grid = me.down('proxmodCronJobGrid');
            var runs = me.down('proxmodCronRuns');

            grid.on('selectionchange', function (view, selection) {
                Proxmod.guard('proxmod-cron runs follow selection', function () {
                    runs.setJob(selection[0] ? selection[0].data.id : undefined);
                });
            });

            grid.on('proxmodcronperms', function (view, perms) {
                Proxmod.guard('proxmod-cron node permissions', function () {
                    me.applyPermissions(perms);
                });
            });

            // A run that ran is only in the history if the history survives.
            // Said once, on the region it is about, rather than left for the
            // administrator to discover after the next reboot.
            me.on('afterrender', function () {
                Proxmod.guard('proxmod-cron journal status', function () {
                    ProxmodCron.api.journalStatus(me.nodename, {
                        success: function (response) {
                            var data = response.result.data || {};
                            if (me.destroyed || data.persistent) {
                                return;
                            }
                            runs.addDocked({
                                xtype: 'component',
                                dock: 'top',
                                cls: 'proxmod-cron-note',
                                html: '<div class="proxmod-cron-warning">'
                                    + enc(gettext('This node\'s journal is'
                                        + ' volatile, so run history is lost at'
                                        + ' reboot. Creating /var/log/journal'
                                        + ' makes it persistent; that is the'
                                        + ' administrator\'s setting for the'
                                        + ' whole host, not this extension\'s.'))
                                    + '</div>',
                            });
                        },
                        failure: function () { /* not worth a dialog */ },
                    });
                });
            });
        },
    });

    // -----------------------------------------------------------------------
    // Styles. One selector namespace in this page, shared with Proxmox, so
    // every class is prefixed.
    // -----------------------------------------------------------------------

    Proxmod.ui.addStyle(EXT, [
        '.proxmod-cron-ok { color: #21BF4B; }',
        '.proxmod-cron-error { color: #FF6C59; }',
        '.proxmod-cron-warning { color: #F0AD4E; }',
        '.proxmod-cron-muted { opacity: 0.7; }',
        '.proxmod-cron-note { font-size: 11px; opacity: 0.85; padding: 4px 0; }',
        '.proxmod-cron-log { font-family: monospace; font-size: 12px;',
        '    white-space: pre-wrap; word-break: break-all; }',
        '.proxmod-cron-log-err { color: #FF6C59; }',
        '.proxmod-cron-log-out { }',
        '.proxmod-cron-log-gap { color: #F0AD4E; text-align: center;',
        '    border-top: 1px dashed currentColor; margin: 4px 0; }',
    ].join('\n'));

    // -----------------------------------------------------------------------
    // Registration. itemId is never set by hand: the generated
    // proxmod-cron[-<id>] is unique by construction, and a collision throws out
    // of insertComponent, which would blank the panel.
    // -----------------------------------------------------------------------

    Proxmod.ui.addDatacenterTab({
        ext: EXT,
        title: gettext('Cron'),
        iconCls: 'fa fa-clock-o',
        xtype: 'proxmodCronJobGrid',
        item: { scope: 'cluster' },
        after: 'options',
    });

    Proxmod.ui.addNodeTab({
        ext: EXT,
        title: gettext('Cron'),
        iconCls: 'fa fa-clock-o',
        xtype: 'proxmodCronNodePanel',
        after: 'system',
    });

    Proxmod.ui.addMenuScreen({
        ext: EXT,
        targets: ['node'],
        id: 'inventory',
        title: gettext('Cron Inventory'),
        iconCls: 'fa fa-list',
        xtype: 'proxmodCronInventory',
    });
})();

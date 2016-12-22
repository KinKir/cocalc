###
Server side synchronized tables built on PostgreSQL, and basic support
for user get query updates.

**
This code is currently NOT released under any license for use by anybody except SageMath, Inc.

(c) 2016 SageMath, Inc.
**

###

EventEmitter = require('events')

immutable    = require('immutable')
async        = require('async')

{defaults} = misc = require('smc-util/misc')
required = defaults.required
misc_node = require('smc-util-node/misc_node')

{PostgreSQL, pg_type, one_result, all_results} = require('./postgres')
{quote_field} = require('./postgres-base')

{SCHEMA} = require('smc-util/schema')


class exports.PostgreSQL extends PostgreSQL

    _ensure_trigger_exists: (table, select, watch, cb) =>
        dbg = @_dbg("_ensure_trigger_exists(#{table})")
        dbg("select=#{misc.to_json(select)}")
        if misc.len(select) == 0
            cb('there must be at least one column selected')
            return
        tgname = trigger_name(table, select, watch)
        trigger_exists = undefined
        async.series([
            (cb) =>
                dbg("checking whether or not trigger exists")
                @_query
                    query : "SELECT count(*) FROM pg_trigger WHERE tgname = '#{tgname}'"
                    cb    : (err, result) =>
                        if err
                            cb(err)
                        else
                            trigger_exists = parseInt(result.rows[0].count) > 0
                            cb()
            (cb) =>
                if trigger_exists
                    dbg("trigger #{tgname} already exists")
                    cb()
                    return
                dbg("creating trigger #{tgname}")
                @_query
                    query : trigger_code(table, select, watch)
                    cb    : cb
        ], cb)

    _listen: (table, select, watch, cb) =>
        dbg = @_dbg("_listen(#{table})")
        dbg("select = #{misc.to_json(select)}")
        if not misc.is_object(select)
            cb('select must be an object')
            return
        if misc.len(select) == 0
            cb('there must be at least one column')
            return
        if not misc.is_array(watch)
            cb('watch must be an array')
            return
        @_listening ?= {}
        tgname = trigger_name(table, select, watch)
        if @_listening[tgname] > 0
            dbg("already listening")
            @_listening[tgname] += 1
            cb?(undefined, tgname)
            return
        async.series([
            (cb) =>
                dbg("ensure trigger exists")
                @_ensure_trigger_exists(table, select, watch, cb)
            (cb) =>
                dbg("add listener")
                @_query
                    query : "LISTEN #{tgname}"
                    cb    : cb
        ], (err) =>
            if err
                dbg("fail: err = #{err}")
                cb?(err)
            else
                @_listening[tgname] ?= 0
                @_listening[tgname] += 1
                dbg("success")
                cb?(undefined, tgname)
        )

    _notification: (mesg) =>
        @_dbg('notification')(misc.to_json(mesg))
        @emit(mesg.channel, JSON.parse(mesg.payload))

    _stop_listening: (table, select, watch, cb) =>
        @_listening ?= {}
        tgname = trigger_name(table, select, watch)
        if not @_listening[tgname]? or @_listening[tgname] == 0
            cb?()
            return
        if @_listening[tgname] > 0
            @_listening[tgname] -= 1
        if @_listening[tgname] == 0
            @_query
                query : "UNLISTEN #{tgname}"
                cb    : cb

    # Server-side changefeed-updated table, which automatically restart changefeed
    # on error, etc.  See SyncTable docs where the class is defined.
    synctable: (opts) =>
        opts = defaults opts,
            table    : required
            columns  : undefined
            where    : undefined
            limit    : undefined
            order_by : undefined
            idle_timeout_s : undefined   # TODO: currently ignored
            cb       : required
        new SyncTable(@, opts.table, opts.columns, opts.where, opts.limit, opts.order_by, opts.cb)
        return

    changefeed: (opts) =>
        opts = defaults opts,
            table  : required   # Name of the table
            select : required   # Map from field names to postgres data types. These must
                                # determine entries of table (e.g., primary key).
            watch  : required   # Array of field names we watch for changes
            where  : required   # Condition involving only the fields in select; or function taking obj with select and returning true or false
            cb     : required
        new Changes(@, opts.table, opts.select, opts.watch, opts.where, opts.cb)
        return

    # Event emitter that
    project_and_user_tracker: (opts) =>
        opts = defaults opts,
            cb : required
        if @_project_and_user_tracker?
            opts.cb(undefined, @_project_and_user_tracker)
            return
        @_project_and_user_tracker_cbs ?= []
        @_project_and_user_tracker_cbs.push(opts.cb)
        if @_project_and_user_tracker_cbs.length == 1
            x = new ProjectAndUserTracker @, (err) =>
                if not err
                    @_project_and_user_tracker = x
                else
                    x = undefined
                for cb in @_project_and_user_tracker_cbs
                    cb?(err, x)
                delete @_project_and_user_tracker_cbs


class ProjectAndUserTracker extends EventEmitter
    constructor: (@_db, cb) ->
        # by a "set" we mean map to bool
        @_accounts = {} # set of accounts we care about
        @_users    = {} # map from from project_id to set of users of a given project
        @_projects = {} # map from account_id to set of projects of a given user
        @_collabs  = {} # map from account_id to map from account_ids to *number* of projects you have in common
        # create changefeed listening on changes to projects table
        # TODO: instead of firing on users change; fire on change of jsonb_object_keys(users),
        # which should be easy via more customized triggers... or a custom postgres VIEW.
        @_db.changefeed
            table  : 'projects'
            select : {project_id:'UUID'}
            watch  : ['users']
            where  : {}
            cb     : (err, feed) =>
                if err
                    cb(err)
                else
                    @_feed = feed
                    @_feed.on 'change', @_handle_change
                    cb()

    close: =>
        @emit('close')
        @removeAllListeners()
        @_feed.close()

    _handle_change: (x) =>
        if x.action == 'delete'
            project_id = x.old_val.project_id
            if not @_users[project_id]?
                # no users
                return
            for account_id of @_users[project_id]
                @_remove_user_from_project(account_id, project_id)
            return
        # users on a project changed or project created
        project_id = x.new_val.project_id
        @_db._query
            query : "SELECT jsonb_object_keys(users) AS account_id FROM projects"
            where : "project_id = $::UUID":project_id
            cb    : all_results 'account_id', (err, users) =>
                if err
                    # TODO! -- will have to try again... or make a version of _query that can't fail...?
                    return
                if not @_users[project_id]?
                    # we are not already watching this project
                    any = false
                    for account_id in users
                        if @_accounts[account_id]
                            any = true
                            break
                    if not any
                        # *and* none of our tracked users are on this project... so don't care
                        return

                # first add any users who got added, and record which accounts are relevant
                users_now    = {}
                for account_id in users
                    users_now[account_id] = true
                users_before = @_users[project_id] ? {}
                for account_id of users_now
                    if not users_before[account_id]
                        @_add_user_to_project(account_id, project_id)
                for account_id of users_before
                    if not users_now[account_id]
                        @_remove_user_from_project(account_id, project_id)

    # add and remove user from a project, maintaining our data structures (@_accounts, @_projects, @_collabs)
    _add_user_to_project: (account_id, project_id) =>
        if account_id?.length != 36 or project_id?.length != 36
            throw Error("invalid account_id or project_id")
        if @_projects[account_id]?[project_id]
            return
        @emit 'add_user_to_project', {account_id:account_id, project_id:project_id}
        users = @_users[project_id] ?= {}
        users[account_id] = true
        projects = @_projects[account_id] ?= {}
        projects[project_id] = true
        collabs = @_collabs[account_id] ?= {}
        for other_account_id of users
            if collabs[other_account_id]?
                collabs[other_account_id] += 1
            else
                collabs[other_account_id] = 1
                @emit 'add_collaborator', {account_id:account_id, collab_id:other_account_id}
            other_collabs = @_collabs[other_account_id]
            if other_collabs[account_id]?
                other_collabs[account_id] += 1
            else
                other_collabs[account_id] = 1
                @emit 'add_collaborator', {account_id:other_account_id, collab_id:account_id}

    _remove_user_from_project: (account_id, project_id, no_emit) =>
        if account_id?.length != 36 or project_id?.length != 36
            throw Error("invalid account_id or project_id")
        if not @_projects[account_id]?[project_id]
            return
        if not no_emit
            @emit 'remove_user_from_project', {account_id:account_id, project_id:project_id}
        collabs = @_collabs[account_id] ?= {}
        for other_account_id of @_users[project_id]
            @_collabs[account_id][other_account_id] -= 1
            if @_collabs[account_id][other_account_id] == 0
                delete @_collabs[account_id][other_account_id]
                if not no_emit
                    @emit 'remove_collaborator', {account_id:account_id, collab_id:other_account_id}
            @_collabs[other_account_id][account_id] -= 1
            if @_collabs[other_account_id][account_id] == 0
                delete @_collabs[other_account_id][account_id]
                if not no_emit
                    @emit 'remove_collaborator', {account_id:other_account_id, collab_id:account_id}
        delete @_users[project_id][account_id]
        delete @_projects[account_id][project_id]

    # TODO: only register one at a time!!
    register: (opts) =>
        opts = defaults opts,
            account_id : required
            cb         : required
        if @_accounts[opts.account_id]?
            # already registered
            opts.cb()
            return
        if not @_register_cbs?
            @_register_cbs = [opts.cb]
        else
            @_register_cbs.push(opts.cb)
        if @_register_cbs.length > 1
            return
        @_db._query
            query  : "SELECT project_id, json_agg(o) as users FROM (select project_id, jsonb_object_keys(users) AS o FROM projects WHERE users ? $1::TEXT) s group by s.project_id"
            params : [opts.account_id]
            cb     : all_results (err, x) =>
                if err
                    for cb in @_register_cbs
                        cb(err)
                    delete @_register_cbs
                    return
                @_accounts[opts.account_id] = true
                for a in x
                    if @_users[a.project_id]?
                        # already have data about this project
                        continue
                    else
                        for account_id in a.users
                            @_add_user_to_project(account_id, a.project_id)
                for cb in @_register_cbs
                    cb()
                delete @_register_cbs

    unregister: (opts) =>
        opts = defaults opts,
            account_id : required
        if not @_accounts[opts.account_id]?
            return
        v = []
        for project_id of @_projects[opts.account_id]
            v.push(project_id)
        delete @_accounts[opts.account_id]
        # Forget about any projects they were on that are no longer
        # necessary to watch...
        for project_id in v
            need = false
            for account_id of @_users[project_id]
                if @_accounts[account_id]?
                    need = true
                    break
            if not need
                for account_id of @_users[project_id]
                    @_remove_user_from_project(account_id, project_id, true)
                delete @_users[project_id]
        return


    # return *set* of projects that this user is a collaborator on
    projects: (account_id) =>
        if not @_accounts[account_id]?
            throw Error("account (='#{account_id}') must be registered")
        return @_projects[account_id] ? {}

    # map from collabs of account_id to number of projects they collab on (account_id itself counted twice)
    collabs: (account_id) =>
        return @_collabs[account_id]


class Changes extends EventEmitter
    constructor: (@_db, @_table, @_select, @_watch, @_where, cb) ->
        @dbg = @_db._dbg("ChangeFeed(table='#{@_table}')")
        @dbg("select=#{misc.to_json(@_select)}, watch=#{misc.to_json(@_watch)}, @_where=#{misc.to_json(@_where)}")
        @_init_where()
        @_db._listen @_table, @_select, @_watch, (err, tgname) =>
            if err
                cb(err); return
            @_tgname = tgname
            @_db.on(@_tgname, @_handle_change)
            cb(undefined, @)

    close: (cb) =>
        @emit('close', {action:'close'})
        @removeAllListeners()
        @_db.removeListener(@_tgname, @_handle_change)
        @_db._stop_listening(@_table, @_select, @_watch, cb)
        delete @_tgname
        delete @_condition

    _old_val: (result, action, mesg) =>
        # include only changed fields if action is 'update'
        if action == 'update'
            old_val = {}
            for field, val of mesg[1]
                old = mesg[2][field]
                if val != old
                   old_val[field] = old
            if misc.len(old_val) > 0
                result.old_val = old_val

    _handle_change: (mesg) =>
        #console.log '_handle_change', mesg
        if mesg[0] == 'DELETE'
            if not @_match_condition(mesg[2])
                return
            @emit('change', {action:'delete', old_val:mesg[2]})
        else
            action = "#{mesg[0].toLowerCase()}"
            if not @_match_condition(mesg[1])
                if action != 'update'
                    return
                for k, v of mesg[1]
                    if not mesg[2][k]?
                        mesg[2][k] = v
                    if @_match_condition(mesg[2])
                        @emit('change', {action:'delete', old_val:mesg[2]})
                    return
            if @_watch.length == 0
                r = {action:action, new_val:mesg[1]}
                @_old_val(r, action, mesg)
                @emit('change', r)
                return
            where = {}
            for k, v of mesg[1]
                where["#{k} = $"] = v
            @_db._query
                select: @_watch
                table : @_table
                where : where
                cb    : one_result (err, result) =>
                    if err
                        @emit('error', err)
                        return
                    if not result?
                        # This happens when record isn't deleted, but some
                        # update results in the object being removed from our
                        # selection criterion... which we view as "delete".
                        @emit('change', {action:'delete', old_val:mesg[1]})
                        return
                    r = {action:action, new_val:misc.merge(result, mesg[1])}
                    @_old_val(r, action, mesg)
                    @emit('change', r)

    insert: (where) =>
        where0 = {}
        for k, v of where
            where0["#{k} = $"] = v
        @_db._query
            select : @_watch.concat(misc.keys(@_select))
            table  : @_table
            where  : where0
            cb     : all_results (err, results) =>
                if err
                    # TODO -- what to do -- some ugly thing involving trying again.
                    # really just need a notion of queries that can't fail unless
                    # they are erronous.
                else
                    for x in results
                        if @_match_condition(x)
                            @emit('change', {action:'insert', new_val:x})
    delete: (where) =>
        # listener is meant to delete everything that *matches* the where, so
        # there is no need to actually do a query.
        @emit('change', {action:'delete', old_val:where})

    _init_where: =>
        if typeof(@_where) == 'function'
            # user provided function
            @_match_condition = @_where
            return
        if misc.is_object(@_where)
            w = [@_where]
        else
            w = @_where

        @_condition = {}
        add_condition = (field, op, val) =>
            field = field.trim()
            if field[0] == '"'  # de-quote
                field = field.slice(1,field.length-1)
            if not @_select[field]?
                throw Error("'#{field}' must be in select")
            if misc.is_object(val)
                throw Error("val (=#{misc.to_json(val)}) must not be an object")
            if misc.is_array(val)
                if op == '=' or op == '=='
                    # containment
                    f = (x) ->
                        for v in val
                            if x == v
                                return true
                        return false
                else if op == '!=' or op == '<>'
                    # not contained in
                    f = (x) ->
                        for v in val
                            if x == v
                                return false
                        return true
                else
                    throw Error("if val is an array, then op must be = or !=")
            else if misc.is_date(val)
                # Inputs to condition come back as JSON, which doesn't know
                # about timestamps, so we convert them to date objects.
                if op in ['=', '==']
                    f = (x) -> (new Date(x) - val == 0)
                else if op in ['!=', '<>']
                    f = (x) -> (new Date(x) - val != 0)
                else
                    g = misc.op_to_function(op)
                    f = (x) -> g(new Date(x), val)
            else
                g = misc.op_to_function(op)
                f = (x) -> g(x, val)
            @_condition[field] = f

        for obj in w
            if misc.is_object(obj)
                for k, val of obj
                    ###
                    k should be of one of the following forms
                       - "field op $::TYPE"
                       - "field op $" or
                       - "field op any($)"
                       - 'field' (defaults to =)
                    where op is one of =, <, >, <=, >=, !=

                    val must be:
                       - something where javascript === and comparisons works as you expect!
                       - or an array, in which case op must be = or !=, and we ALWAYS do inclusion (analogue of any).
                    ###
                    found = false
                    for op in misc.operators
                        i = k.indexOf(op)
                        if i != -1
                            add_condition(k.slice(0, i).trim(), op, val)
                            found = true
                            break
                    if not found
                        throw Error("unable to parse '#{k}'")
            else if typeof(obj) == 'string'
                found = false
                for op in misc.operators
                    i = obj.indexOf(op)
                    if i != -1
                        add_condition(obj.slice(0, i), op, eval(obj.slice(i+op.length).trim()))
                        found = true
                        break
                if not found
                    throw Error("unable to parse '#{obj}'")
            else
                throw Error("NotImplementedError")
        if misc.len(@_condition) == 0
            delete @_condition

        @_match_condition = (obj) =>
            #console.log '_match_condition', obj
            if not @_condition?
                return true
            for field, f of @_condition
                if not f(obj[field])
                    #console.log 'failed due to field ', field
                    return false
            return true


# TODO: Make SyncTable robust to database reconnects.
class SyncTable extends EventEmitter
    constructor: (@_db, @_table, @_columns, @_where, @_limit, @_order_by, cb) ->
        t = SCHEMA[@_table]
        if not t?
            @_state = 'error'
            cb("unknown table #{@_table}")
            return

        try
            @_primary_key = @_db._primary_key(@_table)
        catch e
            cb(e)
            return

        @_listen_columns = {"#{@_primary_key}" : pg_type(t.fields[@_primary_key], @_primary_key)}

        if @_columns
            if @_primary_key not in @_columns
                @_columns = @_columns.concat([@_primary_key])  # required
            @_select_columns = @_columns
        else
            @_select_columns = misc.keys(SCHEMA[@_table].fields)

        @_select_query = "SELECT #{(quote_field(x) for x in @_select_columns)} FROM #{@_table}"

        @_init (err) => cb(err, @)

    _dbg: (f) =>
        return @_db._dbg("SyncTable.#{f}")

    _query_opts: () =>
        opts = {}
        opts.query = @_select_query
        opts.where = @_where
        opts.limit = @_limit
        opts.order_by = @_order_by
        return opts

    close: (cb) =>
        @removeAllListeners()
        @_db.removeListener(@_tgname, @_notification)
        delete @_value
        @_state = 'closed'
        @_db._stop_listening(@_table, @_listen_columns, [], cb)

    connect: (opts) =>
        opts?.cb?() # NO-OP -- only needed for backward compatibility

    _notification: (obj) =>
        #console.log 'notification', obj
        [action, new_val, old_val] = obj
        if action == 'DELETE' or not new_val?
            k = old_val[@_primary_key]
            if @_value.has(k)
                @_value = @_value.delete(k)
                process.nextTick(=>@emit('change', k))
        else
            @_changed[new_val[@_primary_key]] = true
            @_update()

    _init: (cb) =>
        @_state = 'init' # 'init' -> ['error', 'ready'] -> 'closed'
        @_value = immutable.Map()
        @_changed = {}
        async.series([
            (cb) =>
                # ensure database client is listen for primary keys changes to our table
                @_db._listen @_table, @_listen_columns, [], (err, tgname) =>
                    @_tgname = tgname
                    @_db.on(@_tgname, @_notification)
                    cb(err)
            (cb) =>
                opts = @_query_opts()
                opts.cb = (err, result) =>
                    if err
                        cb(err)
                    else
                        @_process_results(result.rows)
                        cb()
                @_db._query(opts)
            (cb) =>
                @_update(cb)
            ], (err) =>
                if err
                    @_state = 'error'
                    cb(err)
                else
                    @_state = 'ready'
                    cb()
            )

    _process_results: (rows) =>
        for x in rows
            k = x[@_primary_key]
            v = immutable.fromJS(misc.map_without_undefined(x))
            if not v.equals(@_value.get(k))
                @_value = @_value.set(k, v)
                if @_state == 'ready'   # only send out change notifications after ready.
                    process.nextTick(=>@emit('change', k))

    # Grab any entries from table about which we have been notified of changes.
    _update: (cb) =>
        if misc.len(@_changed) == 0 # nothing to do
            cb?()
            return
        changed = @_changed
        @_changed = {}  # reset changed set -- could get modified during query below, which is fine.
        if @_select_columns.length == 1  # special case where we don't have to query for more info
            @_process_results((("#{@_primary_key}" : x) for x in misc.keys(changed)))
            cb?()
            return

        # Have to query to get actual changed data.
        @_db._query
            query : @_select_query
            where : misc.merge("#{@_primary_key} = ANY($)" : misc.keys(changed), @_where)
            cb    : (err, result) =>
                if err
                    @_dbg("update")("error #{err}")
                    for k of changed
                        @_changed[k] = true   # will try again later
                else
                    @_process_results(result.rows)
                cb?()

    get: (key) =>
        return if key? then @_value.get(key) else @_value

    getIn: (x) =>
        return @_value.getIn(x)

    has: (key) =>
        return @_value.has(key)

    # wait until some function of this synctable is truthy
    wait: (opts) =>
        opts = defaults opts,
            until   : required     # waits until "until(@)" evaluates to something truthy
            timeout : 30           # in *seconds* -- set to 0 to disable (sort of DANGEROUS if 0, obviously.)
            cb      : required     # cb(undefined, until(@)) on success and cb('timeout') on failure due to timeout
        x = opts.until(@)
        if x
            opts.cb(undefined, x)  # already true
            return
        fail_timer = undefined
        f = =>
            x = opts.until(@)
            if x
                @removeListener('change', f)
                if fail_timer?
                    clearTimeout(fail_timer)
                    fail_timer = undefined
                opts.cb(undefined, x)
        @on('change', f)
        if opts.timeout
            fail = =>
                @removeListener('change', f)
                opts.cb('timeout')
            fail_timer = setTimeout(fail, 1000*opts.timeout)
        return

###
Trigger functions
###
trigger_name = (table, select, watch) ->
    if not misc.is_object(select)
        throw Error("trigger_name -- columns must be a map of colname:type")
    c = misc.keys(select)
    c.sort()
    watch = misc.copy(watch)
    watch.sort()
    if watch.length > 0
        c.push('|')
        c = c.concat(watch)
    return 'change_' + misc_node.sha1("#{table} #{c.join(' ')}").slice(0,16)

###
INPUT:
    table  -- name of a table
    select -- map from field names (of table) to their postgres types
    change -- array of field names (of table)

Creates a trigger function that fires whenever any of the given
columns changes, and sends the columns in select out as a notification.
###

trigger_code = (table, select, watch) ->
    tgname          = trigger_name(table, select, watch)
    column_decl_old = ("#{field}_old #{type ? 'text'};"   for field, type of select)
    column_decl_new = ("#{field}_new #{type ? 'text'};"   for field, type of select)
    assign_old      = ("#{field}_old = OLD.#{field};"     for field, _ of select)
    assign_new      = ("#{field}_new = NEW.#{field};"     for field, _ of select)
    build_obj_old   = ("'#{field}', #{field}_old"         for field, _ of select)
    build_obj_new   = ("'#{field}', #{field}_new"         for field, _ of select)
    if watch.length > 0
        no_change   = ("OLD.#{field} = NEW.#{field}" for field in watch.concat(misc.keys(select))).join(' AND ')
    else
        no_change = 'FALSE'
    if watch.length > 0
        x = {}
        for k in watch
            x[k] = true
        for k in misc.keys(select)
            x[k] = true
        update_of = "OF #{(quote_field(field) for field in misc.keys(x)).join(',')}"
    else
        update_of = ""
    code = """
CREATE OR REPLACE FUNCTION #{tgname}() RETURNS TRIGGER AS $$
    DECLARE
        notification json;
        obj_old json;
        obj_new json;
        #{column_decl_old.join('\n')}
        #{column_decl_new.join('\n')}
    BEGIN
        -- TG_OP is 'DELETE', 'INSERT' or 'UPDATE'
        IF TG_OP = 'DELETE' THEN
            #{assign_old.join('\n')}
            obj_old = json_build_object(#{build_obj_old.join(',')});
        END IF;
        IF TG_OP = 'INSERT' THEN
            #{assign_new.join('\n')}
            obj_new = json_build_object(#{build_obj_new.join(',')});
        END IF;
        IF TG_OP = 'UPDATE' THEN
            IF #{no_change} THEN
                RETURN NULL;
            END IF;
            #{assign_old.join('\n')}
            obj_old = json_build_object(#{build_obj_old.join(',')});
            #{assign_new.join('\n')}
            obj_new = json_build_object(#{build_obj_new.join(',')});
        END IF;
        notification = json_build_array(TG_OP, obj_new, obj_old);
        PERFORM pg_notify('#{tgname}', notification::text);
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER #{tgname} AFTER INSERT OR DELETE OR UPDATE #{update_of} ON #{table} FOR EACH ROW EXECUTE PROCEDURE #{tgname}();
"""
    return code

parse_cond = (cond) ->
    # TODO hack for now -- there must be space
    i = cond.indexOf(' ')
    if i == -1
        return {field:cond}
    else
        return {field:cond.slice(0,i)}



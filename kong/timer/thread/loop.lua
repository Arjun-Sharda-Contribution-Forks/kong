local utils = require("kong.timer.utils")

-- luacheck: push ignore
local ngx_log = ngx.log
local ngx_STDERR = ngx.STDERR
local ngx_EMERG = ngx.EMERG
local ngx_ALERT = ngx.ALERT
local ngx_CRIT = ngx.CRIT
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_NOTICE = ngx.NOTICE
local ngx_INFO = ngx.INFO
local ngx_DEBUG = ngx.DEBUG
-- luacheck: pop

-- luacheck: push ignore
local assert = utils.assert
-- luacheck: pop

local ngx_timer_at = ngx.timer.at
local ngx_worker_exiting = ngx.worker.exiting

local string_format = string.format

local table_unpack = table.unpack

local setmetatable = setmetatable
local error = error
local pcall = pcall


local _M = {
    ACTION_CONTINUE = 1,
    ACTION_ERROR = 2,
    ACTION_EXIT = 3,
    ACTION_EXIT_WITH_MSG = 4,
    ACTION_RESTART = 5,

    LOG_FORMAT_SPAWN = "thread %s has been spawned",
    LOG_FORMAT_ERROR_SPAWN =
        "failed to spawn thread %s: %s",

    LOG_FORMAT_START = "thread %s has been started",
    LOG_FORMAT_EXIT = "thread %s has been exited",

    LOG_FORMAT_ERROR_INIT =
        "thread %s will exits after initializing: %s",
    LOG_FORMAT_EXIT_INIT =
        "thread %s will exits atfer initializing",
    LOG_FORMAT_EXIT_WITH_MSG_INIT =
        "thread %s will exits atfer initializing: %s",
    LOG_FORMAT_RESTART_INIT =
        "thread %s will be restarted after initializing",

    LOG_FORMAT_ERROR_BEFORE =
        "thread %s will exits after the before_callback is executed: %s",
    LOG_FORMAT_EXIT_BEFORE =
        "thread %s will exits after the before_callback body is executed",
    LOG_FORMAT_EXIT_WITH_MSG_BEFORE =
        "thread %s will exits after the before_callback body is executed: %s",
    LOG_FORMAT_RESTART_BEFORE =
        "thread %s will be restarted after the before_callback body is executed",

    LOG_FORMAT_ERROR_LOOP_BODY =
        "thread %s will exits after the loop body is executed: %s",
    LOG_FORMAT_EXIT_LOOP_BODY =
        "thread %s will exits after the loop body is executed",
    LOG_FORMAT_EXIT_WITH_MSG_LOOP_BODY =
        "thread %s will exits after the loop body is executed: %s",
    LOG_FORMAT_RESTART_LOOP_BODY =
        "thread %s will be restarted after the loop body is executed",

    LOG_FORMAT_ERROR_AFTER =
        "thread %s will exits after the after_callback is executed: %s",
    LOG_FORMAT_EXIT_AFTER =
        "thread %s will exits after the after_callback body is executed",
    LOG_FORMAT_EXIT_WITH_MSG_AFTER =
        "thread %s will exits after the after_callback body is executed: %s",
    LOG_FORMAT_RESTART_AFTER =
        "thread %s will be restarted after the after_callback body is executed",

    LOG_FORMAT_ERROR_FINALLY =
        "thread %s will exits after the finally_callback is executed: %s",
    LOG_FORMAT_RESTART_FINALLY =
        "thread %s will be restarted after the finally_callback body is executed",
}

local meta_table = {
    __index = _M,
}


local function callback_wrapper(self, check_worker_exiting, callback, ...)
    local ok, action_or_err, err_or_nil = pcall(callback, self.context, ...)

    if not ok then
        return _M.ACTION_ERROR, action_or_err
    end

    local action = action_or_err
    local err = err_or_nil

    if action == _M.ACTION_CONTINUE or
       action == _M.ACTION_RESTART
    then
        if check_worker_exiting and ngx_worker_exiting() then
            return _M.ACTION_EXIT_WITH_MSG, "worker exiting"
        end

        if self._kill then
            return _M.ACTION_EXIT_WITH_MSG, "killed"
        end

        return action
    end

    if action == _M.ACTION_EXIT then
        return action
    end

    if action == _M.ACTION_EXIT_WITH_MSG then
        return action, err
    end

    if action == _M.ACTION_ERROR then
        assert(err ~= nil)
        return _M.ACTION_ERROR, err
    end

    error("unexpected error")
end


local function nop()
    return _M.ACTION_CONTINUE
end


local function loop_wrapper(premature, self)
    if premature then
        return
    end

    ngx_log(ngx_NOTICE,
            string_format(_M.LOG_FORMAT_START,
                          self.name))

    local action, err
    local before = self.before
    local loop_body = self.loop_body
    local after = self.after

    action, err = self.init()

    if action == _M.ACTION_ERROR then
        ngx_log(ngx_EMERG,
                string_format(_M.LOG_FORMAT_ERROR_INIT,
                    self.name, err))
        goto finally
    end

    if action == _M.ACTION_EXIT then
        ngx_log(ngx_NOTICE,
                string_format(
                    _M.LOG_FORMAT_EXIT_INIT,
                    self.name))
        goto finally
    end

    if action == _M.ACTION_EXIT_WITH_MSG then
        ngx_log(ngx_NOTICE,
                string_format(
                    _M.LOG_FORMAT_EXIT_WITH_MSG_INIT,
                    self.name, err))
        goto finally
    end

    if action == _M.ACTION_RESTART then
        ngx_log(ngx_NOTICE,
                string_format(
                    _M.LOG_FORMAT_RESTART_INIT,
                    self.name
                ))
        self:spawn()
        goto finally
    end

    assert(action == _M.ACTION_CONTINUE)

    while not ngx_worker_exiting() and not self._kill do
        action, err = before()
        -- ngx_log(ngx_ERR, "CCCCCCCC-", action)

        if action == _M.ACTION_ERROR then
            ngx_log(ngx_EMERG,
                    string_format(_M.LOG_FORMAT_ERROR_BEFORE,
                                  self.name, err))
            break
        end

        if action == _M.ACTION_EXIT then
            ngx_log(ngx_NOTICE,
                    string_format(_M.LOG_FORMAT_EXIT_BEFORE,
                                  self.name))
            break
        end

        if action == _M.ACTION_EXIT_WITH_MSG then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_EXIT_WITH_MSG_BEFORE,
                        self.name, err))
            break
        end

        if action == _M.ACTION_RESTART then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_RESTART_BEFORE,
                        self.name
                    ))
            self:spawn()
            break
        end

        assert(action == _M.ACTION_CONTINUE)

        action, err = loop_body()

        if action == _M.ACTION_ERROR then
            ngx_log(ngx_EMERG,
                    string_format(_M.LOG_FORMAT_ERROR_LOOP_BODY,
                                  self.name, err))
            break
        end

        if action == _M.ACTION_EXIT then
            ngx_log(ngx_NOTICE,
                    string_format(_M.LOG_FORMAT_EXIT_LOOP_BODY,
                                  self.name))
        end

        if action == _M.ACTION_EXIT_WITH_MSG then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_EXIT_WITH_MSG_LOOP_BODY,
                        self.name, err))
            break
        end

        if action == _M.ACTION_RESTART then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_RESTART_LOOP_BODY,
                        self.name
                    ))
            self:spawn()
            break
        end

        assert(action == _M.ACTION_CONTINUE)

        action, err = after()

        if action == _M.ACTION_ERROR then
            ngx_log(ngx_EMERG,
                    string_format(_M.LOG_FORMAT_ERROR_AFTER,
                                  self.name, err))
            break
        end

        if action == _M.ACTION_EXIT then
            ngx_log(ngx_NOTICE,
                    string_format(_M.LOG_FORMAT_EXIT_AFTER,
                                  self.name))
            break
        end

        if action == _M.ACTION_EXIT_WITH_MSG then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_EXIT_WITH_MSG_AFTER,
                        self.name, err))
            break
        end

        if action == _M.ACTION_RESTART then
            ngx_log(ngx_NOTICE,
                    string_format(
                        _M.LOG_FORMAT_RESTART_AFTER,
                        self.name
                    ))
            self:spawn()
            break
        end

        assert(action == _M.ACTION_CONTINUE)
    end

    ::finally::

    action, err = self.finally()

    if action == _M.ACTION_ERROR then
        ngx_log(ngx_EMERG,
                string_format(_M.LOG_FORMAT_ERROR_FINALLY,
                              self.name, err))
    end

    if action == _M.ACTION_RESTART then
        ngx_log(ngx_NOTICE,
                string_format(
                    _M.LOG_FORMAT_RESTART_FINALLY,
                    self.name
                ))
        self:spawn()
    end

    ngx_log(ngx_NOTICE,
            string_format(_M.LOG_FORMAT_EXIT,
                          self.name))
end


local function wrap_callback(self, callback, argc, argv,
                             is_check_worker_exiting)
    return function ()
        return callback_wrapper(self,
                                is_check_worker_exiting,
                                callback,
                                table_unpack(argv, 1, argc))
    end
end


function _M:spawn()
    self._kill = false
    local ok, err = ngx_timer_at(0, loop_wrapper, self)

    if not ok then
        err = string_format(_M.LOG_FORMAT_ERROR_SPAWN,
                            self.name, err)
        ngx_log(ngx_EMERG, err)
        return false, err
    end

    ngx_log(ngx_NOTICE,
            string_format(_M.LOG_FORMAT_SPAWN,
                          self.name))
    return true, nil
end


function _M:kill()
    self._kill = true
end


function _M.new(name, options)
    local self = {
        name = tostring(name),
        context = {},
        _kill = false,
        init = nop,
        before = nop,
        loop_body = nop,
        after = nop,
        finally = nop,
    }

    local check_worker_exiting = true
    local do_not_check_worker_exiting = false

    if options.init then
        self.init = wrap_callback(self,
                                  options.init.callback,
                                  options.init.argc,
                                  options.init.argv,
                                  do_not_check_worker_exiting)
    end

    if options.before then
        self.before = wrap_callback(self,
                                    options.before.callback,
                                    options.before.argc,
                                    options.before.argv,
                                    check_worker_exiting)
    end

    if options.loop_body then
        self.loop_body = wrap_callback(self,
                                       options.loop_body.callback,
                                       options.loop_body.argc,
                                       options.loop_body.argv,
                                       check_worker_exiting)
    end

    if options.after then
        self.after = wrap_callback(self,
                                   options.after.callback,
                                   options.after.argc,
                                   options.after.argv,
                                   do_not_check_worker_exiting)
    end

    if options.finally then
        self.finally = wrap_callback(self,
                                    options.finally.callback,
                                    options.finally.argc,
                                    options.finally.argv,
                                    do_not_check_worker_exiting)
    end

    return setmetatable(self, meta_table)
end


return _M
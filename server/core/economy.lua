-- =====================================================================
--  server/core/economy.lua  —  WCEconomy (ARCHITECTURE.md §6.4)
--  Money is charged BEFORE a transaction and refunded if the transaction fails. Prices are always
--  computed on the server; amounts must be finite, >= 0 and are rounded to cents. A zero amount
--  never touches the framework.
-- =====================================================================

WCEconomy = {}
local E = WCEconomy

local CASH = 0

--- A valid amount rounded to cents, or nil (non-number, NaN, inf, negative).
function E.amount(amount)
    if type(amount) ~= 'number' or not WCUtil.isFinite(amount) or amount < 0 then return nil end
    return WCUtil.round2(amount)
end

local function user(src)
    local ok, u = pcall(function() return w.framework:getUser(src) end)
    if ok and type(u) == 'table' then return u end
    return nil
end

--- Charge cash. Result: ok({ charged }) | INVALID_PRICE | INSUFFICIENT_FUNDS | NO_CHARACTER.
function E.charge(src, amount, reason)
    local value = E.amount(amount)
    if not value then
        WCDebug.warn('economy', 'refused invalid price %s (%s) for %s', tostring(amount), tostring(reason), tostring(src))
        return WCResult.fail('INVALID_PRICE')
    end
    if value == 0 then return WCResult.ok({ charged = 0 }) end
    local u = user(src)
    if not u then return WCResult.fail('NO_CHARACTER') end
    local ok, paid = pcall(u.canBuy, u, value, CASH, true)
    if not ok then
        WCDebug.warn('economy', 'charge failed for %s: %s', tostring(src), tostring(paid))
        return WCResult.fail('INTERNAL_ERROR')
    end
    if paid ~= true then return WCResult.fail('INSUFFICIENT_FUNDS') end
    WCDebug.log('economy', 'charged %s %.2f (%s)', tostring(src), value, tostring(reason))
    return WCResult.ok({ charged = value })
end

--- Give cash back. true when refunded (or nothing to refund).
function E.refund(src, amount, reason)
    local value = E.amount(amount)
    if not value then return false end
    if value == 0 then return true end
    local u = user(src)
    if not u then
        WCDebug.warn('economy', 'refund of %.2f (%s) to %s failed: no user', value, tostring(reason), tostring(src))
        return false
    end
    local ok, result = pcall(u.addMoney, u, value, CASH)
    if not ok or result == false then
        WCDebug.warn('economy', 'refund of %.2f (%s) to %s failed: %s', value, tostring(reason), tostring(src),
            tostring(ok and result or result))
        return false
    end
    return true
end

--- charge -> pcall(persistFn) -> refund on failure. Charges at most once.
--  persistFn returns true / nil / a Result; false, an error or a failed Result counts as failure.
--  Result: the persistFn's Result (or ok(value)) with `charged` set, or the failure (charge failures
--  as-is, persistence failures as the returned Result or DATABASE_ERROR) with data.refunded.
function E.withCharge(src, amount, reason, persistFn)
    local charge = E.charge(src, amount, reason)
    if not charge.ok then return charge end
    local charged = charge.data.charged

    local ok, res, extra = pcall(persistFn)
    local failed = not ok or res == false or (WCResult.is(res) and not res.ok)
    if not failed then
        local result = WCResult.is(res) and res or WCResult.ok(res)
        result.charged = charged
        return result
    end

    local refunded = E.refund(src, charged, reason)
    if not refunded then
        CreatorLogs.Emit('security_violation', {
            playerSource = tonumber(src), kind = 'refund_failed',
            detail = ('%.2f %s'):format(charged, tostring(reason)), reason = 'refund_failed',
        })
    end
    WCDebug.warn('economy', 'persist failed after charging %s %.2f (%s): %s', tostring(src), charged,
        tostring(reason), tostring(ok and (WCResult.is(res) and res.code or extra) or res))
    local failure = (ok and WCResult.is(res)) and res or WCResult.fail('DATABASE_ERROR')
    failure.data = type(failure.data) == 'table' and failure.data or { detail = failure.data }
    failure.data.refunded = refunded
    failure.charged = 0
    return failure
end

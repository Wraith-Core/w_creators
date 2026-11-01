-- =====================================================================
--  server/core/economy.lua  —  WCEconomy (ARCHITECTURE.md §6.4)
--  Money is charged BEFORE a transaction and refunded if the transaction fails. Prices are always
--  computed on the server; amounts must be finite, >= 0 and are rounded to cents. A zero amount
--  never touches the framework.
-- =====================================================================

WCEconomy = {}
local E = WCEconomy

local CASH = 0
--- The framework money types of the currencies a price can name (w_lib's bridge: 0 = cash,
--  1 = gold on every supported core).
E.CURRENCY_IDS = { cash = CASH, gold = 1 }

--- The framework money type of a currency ('cash' when nil), or nil for an unknown one.
function E.currencyId(currency)
    return E.CURRENCY_IDS[currency == nil and 'cash' or currency]
end

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

--- Charge cash (or `currency`: 'cash' | 'gold'). Result: ok({ charged, currency }) | INVALID_PRICE |
--  CURRENCY_NOT_ACCEPTED | INSUFFICIENT_FUNDS | NO_CHARACTER.
function E.charge(src, amount, reason, currency)
    local value = E.amount(amount)
    if not value then
        WCDebug.warn('economy', 'refused invalid price %s (%s) for %s', tostring(amount), tostring(reason), tostring(src))
        return WCResult.fail('INVALID_PRICE')
    end
    local moneyType = E.currencyId(currency)
    if moneyType == nil then return WCResult.fail('CURRENCY_NOT_ACCEPTED') end
    if value == 0 then return WCResult.ok({ charged = 0, currency = currency or 'cash' }) end
    local u = user(src)
    if not u then return WCResult.fail('NO_CHARACTER') end
    -- Avoid a debit call when the observed balance already proves insufficiency. Once the
    -- bridge tries to move money, its boolean false can also mean an unknown ledger commit.
    local read, balance = pcall(u.getMoney, u, moneyType)
    if not read or type(balance) ~= 'number' or not WCUtil.isFinite(balance) then
        return WCResult.fail('ECONOMY_NOT_READY')
    end
    if balance < value then
        -- 1.0.6: the price and what he holds ("the price is $12, you have $5")
        local function shown(n) return n % 1 == 0 and ('%d'):format(n) or ('%.2f'):format(n) end
        return WCResult.detail(WCResult.fail('INSUFFICIENT_FUNDS'), currency == 'gold' and 'funds_gold' or 'funds_cash',
            shown(value), shown(WCUtil.round2(math.max(balance, 0))))
    end
    local ok, paid = pcall(u.canBuy, u, value, moneyType, true)
    if not ok then
        WCDebug.warn('economy', 'charge failed for %s: %s', tostring(src), tostring(paid))
        return WCResult.fail('INTERNAL_ERROR', { paymentUncertain = true })
    end
    if paid ~= true then return WCResult.fail('INSUFFICIENT_FUNDS', { paymentUncertain = true }) end
    WCDebug.log('economy', 'charged %s %.2f %s (%s)', tostring(src), value, tostring(currency or 'cash'), tostring(reason))
    return WCResult.ok({ charged = value, currency = currency or 'cash' })
end

--- Give cash (or `currency`) back. true when refunded (or nothing to refund).
function E.refundOutcome(src, amount, reason, currency)
    local value = E.amount(amount)
    if not value then return false end
    local moneyType = E.currencyId(currency)
    if moneyType == nil then return false end
    if value == 0 then return true end
    local u = user(src)
    if not u then
        WCDebug.warn('economy', 'refund of %.2f (%s) to %s failed: no user', value, tostring(reason), tostring(src))
        return false, 'offline'
    end
    local ok, result = pcall(u.addMoney, u, value, moneyType)
    if not ok or result ~= true then
        WCDebug.warn('economy', 'refund of %.2f (%s) to %s failed: %s', value, tostring(reason), tostring(src),
            tostring(ok and result or result))
        return false, 'uncertain'
    end
    return true, 'confirmed'
end

--- Preserve the public boolean-only API used by resale and other callers.
function E.refund(src, amount, reason, currency)
    local refunded = E.refundOutcome(src, amount, reason, currency)
    return refunded
end

--- charge -> pcall(persistFn) -> refund on failure. Charges at most once.
--  persistFn returns true / nil / a Result; false, an error or a failed Result counts as failure.
--  Result: the persistFn's Result (or ok(value)) with `charged` set, or the failure (charge failures
--  as-is, persistence failures as the returned Result or DATABASE_ERROR) with data.refunded.
--  `currency` ('cash' by default) is charged and refunded alike.
function E.withCharge(src, amount, reason, persistFn, currency)
    local value = E.amount(amount)
    if not value then return WCResult.fail('INVALID_PRICE') end
    if E.currencyId(currency) == nil then return WCResult.fail('CURRENCY_NOT_ACCEPTED') end
    local receipt
    if value > 0 then
        local refusal
        receipt, refusal = WCRefunds.prepare(src, value, currency, reason)
        if not receipt then return refusal end
    end
    local function run()
    local charge = E.charge(src, value, reason, currency)
    if not charge.ok then
        local uncertain = charge.data and charge.data.paymentUncertain
        if receipt then WCRefunds.update(receipt, uncertain and 'review' or 'cancelled') end
        if receipt and uncertain then
            return WCResult.fail('REFUND_REVIEW', { refundId = receipt.id, amount = value,
                currency = currency or 'cash', paymentUncertain = true })
        end
        return charge
    end
    local charged = charge.data.charged
    if receipt then
        local recorded = WCRefunds.update(receipt, 'charged')
        if not recorded then
            local failure = WCResult.fail('REFUND_REVIEW', { refundId = receipt.id, refunded = false })
            failure.charged, failure.currency = charged, currency or 'cash'
            return failure
        end
        receipt = recorded
    end

    local ok, res, extra = pcall(persistFn)
    local failed = not ok or res == false or (WCResult.is(res) and not res.ok)
    if not failed then
        if receipt then WCRefunds.update(receipt, 'delivered') end
        local result = WCResult.is(res) and res or WCResult.ok(res)
        result.charged = charged
        result.currency = currency or 'cash'
        return result
    end

    local refunded, final = charged == 0, receipt
    if receipt then refunded, final = WCRefunds.refund(src, receipt, true) end
    WCDebug.warn('economy', 'persist failed after charging %s %.2f (%s): %s', tostring(src), charged,
        tostring(reason), tostring(ok and (WCResult.is(res) and res.code or extra) or res))
    local failure = (ok and WCResult.is(res)) and res or WCResult.fail('DATABASE_ERROR')
    if not refunded then
        local pending = final and final.state == 'pending'
        failure = WCResult.fail(pending and 'REFUND_PENDING' or 'REFUND_REVIEW')
        CreatorLogs.Emit('security_violation', { playerSource = tonumber(src), kind = 'refund_failed',
            charid = receipt.charid, detail = receipt.id, reason = 'refund_failed' })
    end
    failure.data = type(failure.data) == 'table' and failure.data or { detail = failure.data }
    failure.data.refunded, failure.data.refundId = refunded, receipt and receipt.id or nil
    failure.data.amount, failure.data.currency = charged, currency or 'cash'
    failure.charged = refunded and 0 or charged
    failure.currency = currency or 'cash'
    return failure
    end
    if not receipt then return run() end
    local result, reason = WCRefunds.guard(src, receipt, run)
    if WCResult.is(result) then return result end
    local uncertain = reason == 'generation_callback_failed'
    WCRefunds.update(receipt, uncertain and 'review' or 'cancelled')
    return WCResult.fail(uncertain and 'REFUND_REVIEW' or 'ECONOMY_NOT_READY',
        { refundId = receipt.id, paymentUncertain = uncertain })
end

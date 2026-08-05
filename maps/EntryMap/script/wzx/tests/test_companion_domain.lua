local Harness = require 'wzx.tests.harness'
local CompanionRoster = require 'wzx.domain.companion.roster'
local CompanionAffection = require 'wzx.domain.companion.affection'
local CompanionErrorCodes = require 'wzx.domain.companion.error_codes'

local case = Harness.case
local assert = Harness.assert

local function make_entry(discovery)
    local created = CompanionRoster.create_entry('char_ally', discovery or 'HIDDEN')
    assert.equal(created.ok, true, created.error and created.error.code)
    return created.value
end

local function evidence(receipt_id, source_type)
    return {
        source_type = source_type or 'STORY',
        source_ref = 'quest_main_01',
        receipt_id = receipt_id or 'companion:recruit:char_ally:1',
    }
end

return {
    case('create_entry defaults affection and forbids initial RECRUITED', function()
        local created = CompanionRoster.create_entry('char_ally', 'DISCOVERED')
        assert.equal(created.ok, true)
        assert.equal(created.value.companion_id, 'char_ally')
        assert.equal(created.value.discovery_state, 'DISCOVERED')
        assert.equal(created.value.affection_points, 0)
        assert.equal(created.value.affection_rank, 0)
        assert.equal(created.value.revision, 0)
        assert.is_nil(created.value.availability_state)
        assert.is_nil(created.value.recruited_receipt_id)

        local bad_id = CompanionRoster.create_entry('', 'HIDDEN')
        assert.equal(bad_id.ok, false)
        assert.equal(bad_id.error.code, CompanionErrorCodes.COMPANION_ARGUMENT_INVALID)

        local recruited = CompanionRoster.create_entry('char_ally', 'RECRUITED')
        assert.equal(recruited.ok, false)
        assert.equal(
            recruited.error.code,
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID
        )
    end),

    case('discovery advances forward only and can skip intermediate states', function()
        local entry = make_entry('HIDDEN')

        local stepped = CompanionRoster.advance_discovery(entry, 'DISCOVERED')
        assert.equal(stepped.ok, true)
        assert.equal(stepped.value.discovery_state, 'DISCOVERED')
        assert.equal(stepped.value.revision, 1)

        local skip = CompanionRoster.advance_discovery(stepped.value, 'RECRUITABLE')
        assert.equal(skip.ok, true)
        assert.equal(skip.value.discovery_state, 'RECRUITABLE')
        assert.equal(skip.value.revision, 2)

        local from_hidden = CompanionRoster.advance_discovery(entry, 'RECRUITABLE')
        assert.equal(from_hidden.ok, true)
        assert.equal(from_hidden.value.discovery_state, 'RECRUITABLE')
        assert.equal(from_hidden.value.revision, 1)

        local regress = CompanionRoster.advance_discovery(skip.value, 'DISCOVERED')
        assert.equal(regress.ok, false)
        assert.equal(regress.error.code, CompanionErrorCodes.COMPANION_DISCOVERY_REGRESSION)

        local via_recruit = CompanionRoster.advance_discovery(skip.value, 'RECRUITED')
        assert.equal(via_recruit.ok, false)
        assert.equal(
            via_recruit.error.code,
            CompanionErrorCodes.COMPANION_DISCOVERY_STATE_INVALID
        )

        local same = CompanionRoster.advance_discovery(skip.value, 'RECRUITABLE')
        assert.equal(same.ok, true)
        assert.equal(same.value.revision, 2)
    end),

    case('recruit succeeds, is idempotent on same receipt, already_recruited on different', function()
        local entry = make_entry('RECRUITABLE')
        local receipt_a = 'companion:recruit:char_ally:a'
        local receipt_b = 'companion:recruit:char_ally:b'

        local recruited = CompanionRoster.recruit(entry, evidence(receipt_a, 'SIDE_QUEST'))
        assert.equal(recruited.ok, true)
        assert.equal(recruited.value.already_recruited, false)
        assert.equal(recruited.value.idempotent, false)
        assert.equal(recruited.value.entry.discovery_state, 'RECRUITED')
        assert.equal(recruited.value.entry.availability_state, 'AVAILABLE')
        assert.equal(recruited.value.entry.recruited_receipt_id, receipt_a)
        assert.equal(recruited.value.entry.recruitment_source_type, 'SIDE_QUEST')
        assert.equal(recruited.value.entry.revision, 1)

        local same = CompanionRoster.recruit(recruited.value.entry, evidence(receipt_a, 'SIDE_QUEST'))
        assert.equal(same.ok, true)
        assert.equal(same.value.already_recruited, false)
        assert.equal(same.value.idempotent, true)
        assert.equal(same.value.entry.revision, 1)
        assert.equal(same.value.entry.recruited_receipt_id, receipt_a)

        local other = CompanionRoster.recruit(recruited.value.entry, evidence(receipt_b, 'EVENT'))
        assert.equal(other.ok, true)
        assert.equal(other.value.already_recruited, true)
        assert.equal(other.value.entry.revision, 1)
        assert.equal(other.value.entry.recruited_receipt_id, receipt_a)
        assert.equal(other.value.entry.recruitment_source_type, 'SIDE_QUEST')

        local from_hidden = CompanionRoster.recruit(make_entry('HIDDEN'), evidence(receipt_a))
        assert.equal(from_hidden.ok, true)
        assert.equal(from_hidden.value.entry.discovery_state, 'RECRUITED')

        local bad_evidence = CompanionRoster.recruit(make_entry(), {
            source_type = 'UNKNOWN',
            source_ref = 'x',
            receipt_id = receipt_a,
        })
        assert.equal(bad_evidence.ok, false)
        assert.equal(
            bad_evidence.error.code,
            CompanionErrorCodes.COMPANION_RECRUITMENT_EVIDENCE_INVALID
        )
    end),

    case('availability toggles only when recruited', function()
        local not_recruited = make_entry('RECRUITABLE')
        local denied = CompanionRoster.set_availability(not_recruited, 'AVAILABLE')
        assert.equal(denied.ok, false)
        assert.equal(denied.error.code, CompanionErrorCodes.COMPANION_NOT_RECRUITED)

        local recruited = CompanionRoster.recruit(not_recruited, evidence())
        assert.equal(recruited.ok, true)
        local entry = recruited.value.entry

        local leave = CompanionRoster.set_availability(
            entry,
            'TEMPORARILY_UNAVAILABLE',
            'leave_rule_story_01'
        )
        assert.equal(leave.ok, true)
        assert.equal(leave.value.availability_state, 'TEMPORARILY_UNAVAILABLE')
        assert.equal(leave.value.availability_reason_id, 'leave_rule_story_01')
        assert.equal(leave.value.revision, entry.revision + 1)

        local back = CompanionRoster.set_availability(leave.value, 'AVAILABLE')
        assert.equal(back.ok, true)
        assert.equal(back.value.availability_state, 'AVAILABLE')
        assert.is_nil(back.value.availability_reason_id)

        local bad_state = CompanionRoster.set_availability(entry, 'GONE')
        assert.equal(bad_state.ok, false)
        assert.equal(
            bad_state.error.code,
            CompanionErrorCodes.COMPANION_AVAILABILITY_INVALID
        )
    end),

    case('snapshot is a deep copy', function()
        local recruited = CompanionRoster.recruit(make_entry(), evidence())
        local snap = CompanionRoster.snapshot(recruited.value.entry)
        assert.equal(snap.ok, true)
        snap.value.discovery_state = 'HIDDEN'
        snap.value.resolved_event_ids[1] = 'evt_forged'
        assert.equal(recruited.value.entry.discovery_state, 'RECRUITED')
        assert.equal(#recruited.value.entry.resolved_event_ids, 0)
    end),

    case('resolve_rank uses fixed chapter-1 thresholds', function()
        assert.equal(CompanionAffection.resolve_rank(0).value, 0)
        assert.equal(CompanionAffection.resolve_rank(499).value, 0)
        assert.equal(CompanionAffection.resolve_rank(500).value, 1)
        assert.equal(CompanionAffection.resolve_rank(1499).value, 1)
        assert.equal(CompanionAffection.resolve_rank(1500).value, 2)
        assert.equal(CompanionAffection.resolve_rank(3000).value, 3)
        assert.equal(CompanionAffection.resolve_rank(5500).value, 4)
        assert.equal(CompanionAffection.resolve_rank(8500).value, 5)
        assert.equal(CompanionAffection.resolve_rank(10000).value, 5)
        assert.equal(CompanionAffection.resolve_rank(-1).ok, false)
        assert.equal(CompanionAffection.resolve_rank(10001).ok, false)
    end),

    case('apply_delta crosses multiple ranks and clamps at max', function()
        local entry = make_entry()
        local result = CompanionAffection.apply_delta(
            entry,
            3200,
            'companion:affection:char_ally:jump'
        )
        assert.equal(result.ok, true)
        assert.equal(result.value.previous_points, 0)
        assert.equal(result.value.new_points, 3200)
        assert.equal(result.value.previous_rank, 0)
        assert.equal(result.value.new_rank, 3)
        assert.deep_equal(result.value.crossed_ranks, { 1, 2, 3 })
        assert.equal(result.value.entry.affection_points, 3200)
        assert.equal(result.value.entry.affection_rank, 3)
        assert.equal(result.value.entry.revision, 1)

        local overfill = CompanionAffection.apply_delta(
            result.value.entry,
            10000,
            'companion:affection:char_ally:max'
        )
        assert.equal(overfill.ok, true)
        assert.equal(overfill.value.new_points, 10000)
        assert.equal(overfill.value.new_rank, 5)
        assert.deep_equal(overfill.value.crossed_ranks, { 4, 5 })
        assert.equal(overfill.value.applied_delta, 6800)

        local still_max = CompanionAffection.apply_delta(
            overfill.value.entry,
            100,
            'companion:affection:char_ally:still_max'
        )
        assert.equal(still_max.ok, true)
        assert.equal(still_max.value.new_points, 10000)
        assert.equal(still_max.value.applied_delta, 0)
        assert.deep_equal(still_max.value.crossed_ranks, {})
    end),

    case('negative delta cannot drop below current rank floor', function()
        local entry = make_entry()
        local raised = CompanionAffection.apply_delta(
            entry,
            1600,
            'companion:affection:char_ally:up'
        )
        assert.equal(raised.ok, true)
        assert.equal(raised.value.new_rank, 2)
        assert.equal(raised.value.new_points, 1600)

        local drop = CompanionAffection.apply_delta(
            raised.value.entry,
            -5000,
            'companion:affection:char_ally:down'
        )
        assert.equal(drop.ok, true)
        assert.equal(drop.value.new_points, 1500)
        assert.equal(drop.value.new_rank, 2)
        assert.deep_equal(drop.value.crossed_ranks, {})
        assert.equal(drop.value.applied_delta, -100)

        local again = CompanionAffection.apply_delta(
            drop.value.entry,
            -1,
            'companion:affection:char_ally:down2'
        )
        assert.equal(again.ok, true)
        assert.equal(again.value.new_points, 1500)
        assert.equal(again.value.applied_delta, 0)
    end),

    case('apply_delta is idempotent on same receipt_id', function()
        local entry = make_entry()
        local first = CompanionAffection.apply_delta(
            entry,
            600,
            'companion:affection:char_ally:gift1'
        )
        assert.equal(first.ok, true)
        assert.equal(first.value.idempotent, false)
        assert.equal(first.value.new_points, 600)
        assert.equal(first.value.entry.revision, 1)

        local replay = CompanionAffection.apply_delta(
            first.value.entry,
            9999,
            'companion:affection:char_ally:gift1'
        )
        assert.equal(replay.ok, true)
        assert.equal(replay.value.idempotent, true)
        assert.equal(replay.value.new_points, 600)
        assert.equal(replay.value.entry.affection_points, 600)
        assert.equal(replay.value.entry.revision, 1)
        assert.deep_equal(replay.value.crossed_ranks, { 1 })
    end),

    case('compute_gift_delta formula and invalid args', function()
        local ok = CompanionAffection.compute_gift_delta(10, 3, 15000, 10000)
        assert.equal(ok.ok, true)
        -- floor(floor(10*3*15000/10000)*10000/10000) = floor(floor(45)*1) = 45
        assert.equal(ok.value, 45)

        local with_ctx = CompanionAffection.compute_gift_delta(100, 2, 10000, 5000)
        assert.equal(with_ctx.ok, true)
        -- floor(floor(200*10000/10000)*5000/10000) = floor(200*0.5) = 100
        assert.equal(with_ctx.value, 100)

        local clamp = CompanionAffection.compute_gift_delta(10000, 999, 30000, 30000)
        assert.equal(clamp.ok, true)
        assert.equal(clamp.value, 10000)

        local bad_qty = CompanionAffection.compute_gift_delta(10, 0, 10000, 10000)
        assert.equal(bad_qty.ok, false)
        assert.equal(bad_qty.error.code, CompanionErrorCodes.COMPANION_AFFECTION_INVALID)

        local bad_pref = CompanionAffection.compute_gift_delta(10, 1, -1, 10000)
        assert.equal(bad_pref.ok, false)

        local bad_base = CompanionAffection.compute_gift_delta(-5, 1, 10000, 10000)
        assert.equal(bad_base.ok, false)
    end),
}

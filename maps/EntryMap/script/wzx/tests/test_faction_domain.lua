local Harness = require 'wzx.tests.harness'
local Membership = require 'wzx.domain.faction.membership'
local FactionErrorCodes = require 'wzx.domain.faction.error_codes'

local case = Harness.case
local assert = Harness.assert

local FACTION_A = 'faction_qingyun'
local FACTION_B = 'faction_heishan'
local RANK_1 = 'rank_outer'
local RANK_2 = 'rank_inner'
local RANK_3 = 'rank_elder'

local function ranks_config()
    return {
        { rank_id = RANK_1, order = 1, min_reputation = 0 },
        { rank_id = RANK_2, order = 2, min_reputation = 100 },
        { rank_id = RANK_3, order = 3, min_reputation = 500 },
    }
end

local function join_flow(session, faction_id, begin_cmd, join_cmd, joined_at)
    local candidacy = Membership.begin_candidacy(session, faction_id, begin_cmd)
    assert.equal(candidacy.ok, true, 'begin_candidacy should succeed')
    local joined = Membership.join_faction(
        session,
        faction_id,
        join_cmd,
        joined_at or 1700000000,
        RANK_1
    )
    assert.equal(joined.ok, true, 'join_faction should succeed')
    return candidacy, joined
end

return {
    case('contribution currency maps from faction_id', function()
        assert.equal(
            Membership.contribution_currency_id_for(FACTION_A),
            'currency_faction_qingyun'
        )
        assert.equal(
            Membership.contribution_currency_id_for('custom_gate'),
            'currency_faction_custom_gate'
        )
        assert.is_nil(Membership.contribution_currency_id_for(''))
        assert.is_nil(Membership.contribution_currency_id_for(nil))
    end),

    case('empty session shape', function()
        local session = Membership.empty_session()
        assert.is_nil(session.active_faction_id)
        assert.deep_equal(session.records, {})
        assert.deep_equal(session.receipt_index, {})
        assert.equal(session.revision, 0)
    end),

    case('join flow: candidacy then member with initial rank and zero reputation', function()
        local session = Membership.empty_session()
        local candidacy, joined = join_flow(
            session,
            FACTION_A,
            'cmd_begin_qingyun_01',
            'cmd_join_qingyun_01',
            1700000100
        )

        assert.equal(candidacy.value.status, Membership.STATUS.CANDIDATE)
        assert.equal(joined.value.status, Membership.STATUS.MEMBER)
        assert.equal(joined.value.rank_id, RANK_1)
        assert.equal(joined.value.reputation, 0)
        assert.equal(joined.value.joined_at, 1700000100)
        assert.equal(joined.value.contribution_currency_id, 'currency_faction_qingyun')
        assert.equal(session.active_faction_id, FACTION_A)
        assert.equal(session.revision, 2)
        assert.equal(session.records[FACTION_A].status, 'MEMBER')

        local query = Membership.query(session)
        assert.equal(query.ok, true)
        assert.equal(query.value.faction_id, FACTION_A)
        assert.equal(query.value.membership.rank_id, RANK_1)
        assert.equal(query.value.membership.reputation, 0)

        local filtered = Membership.query(session, FACTION_A)
        assert.equal(filtered.ok, true)
        assert.equal(filtered.value.membership.status, 'MEMBER')
    end),

    case('duplicate command_id is idempotent for begin join and promote', function()
        local session = Membership.empty_session()
        local first_begin = Membership.begin_candidacy(session, FACTION_A, 'cmd_begin_idem')
        assert.equal(first_begin.ok, true)
        local second_begin = Membership.begin_candidacy(session, FACTION_A, 'cmd_begin_idem')
        assert.equal(second_begin.ok, true)
        assert.equal(second_begin.value.command_replay, true)
        assert.equal(session.revision, 1)

        local first_join = Membership.join_faction(
            session,
            FACTION_A,
            'cmd_join_idem',
            100,
            RANK_1
        )
        assert.equal(first_join.ok, true)
        local second_join = Membership.join_faction(
            session,
            FACTION_A,
            'cmd_join_idem',
            100,
            RANK_1
        )
        assert.equal(second_join.ok, true)
        assert.equal(second_join.value.command_replay, true)
        assert.equal(second_join.value.rank_id, RANK_1)
        assert.equal(session.revision, 2)

        Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_rep_for_promote',
            'QUEST',
            'quest_gate_01',
            100
        )
        local first_promote = Membership.promote(
            session,
            FACTION_A,
            'cmd_promote_idem',
            RANK_2,
            ranks_config()
        )
        assert.equal(first_promote.ok, true)
        local second_promote = Membership.promote(
            session,
            FACTION_A,
            'cmd_promote_idem',
            RANK_2,
            ranks_config()
        )
        assert.equal(second_promote.ok, true)
        assert.equal(second_promote.value.command_replay, true)
        assert.equal(second_promote.value.to_rank_id, RANK_2)
        assert.equal(session.records[FACTION_A].rank_id, RANK_2)
    end),

    case('reputation only increases and receipt_id is idempotent', function()
        local session = Membership.empty_session()
        join_flow(session, FACTION_A, 'cmd_begin_rep', 'cmd_join_rep', 200)

        local grant = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_quest_clear_01',
            'QUEST',
            'quest_main_01',
            40
        )
        assert.equal(grant.ok, true)
        assert.equal(grant.value.reputation, 40)
        assert.equal(grant.value.receipt_replay, false)

        local replay = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_quest_clear_01',
            'QUEST',
            'quest_main_01',
            40
        )
        assert.equal(replay.ok, true)
        assert.equal(replay.value.receipt_replay, true)
        assert.equal(replay.value.reputation, 40)
        assert.equal(session.records[FACTION_A].reputation, 40)
        assert.equal(session.revision, 3)

        local second = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_quest_clear_02',
            'COMMISSION',
            'commission_patrol_01',
            15
        )
        assert.equal(second.ok, true)
        assert.equal(second.value.reputation, 55)
        assert.equal(session.records[FACTION_A].reputation, 55)
    end),

    case('illegal reputation delta rejected', function()
        local session = Membership.empty_session()
        join_flow(session, FACTION_A, 'cmd_begin_bad_delta', 'cmd_join_bad_delta', 300)

        local zero = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_zero',
            'QUEST',
            'quest_x',
            0
        )
        assert.error_code(zero, FactionErrorCodes.FACTION_ARGUMENT_INVALID)

        local negative = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_neg',
            'QUEST',
            'quest_x',
            -5
        )
        assert.error_code(negative, FactionErrorCodes.FACTION_ARGUMENT_INVALID)

        local float = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_float',
            'QUEST',
            'quest_x',
            1.5
        )
        assert.error_code(float, FactionErrorCodes.FACTION_ARGUMENT_INVALID)

        session.records[FACTION_A].reputation = 2147483647
        local overflow = Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_overflow',
            'ADMIN_RECOVERY',
            'admin_fix',
            1
        )
        assert.error_code(overflow, FactionErrorCodes.FACTION_VALUE_OVERFLOW)
        assert.equal(session.records[FACTION_A].reputation, 2147483647)
    end),

    case('promotion eligibility fails then succeeds after reputation threshold', function()
        local session = Membership.empty_session()
        join_flow(session, FACTION_A, 'cmd_begin_promo', 'cmd_join_promo', 400)
        local ranks = ranks_config()

        local not_ready = Membership.can_promote(session, FACTION_A, ranks, RANK_2)
        assert.error_code(not_ready, FactionErrorCodes.FACTION_PROMOTION_NOT_READY)

        local skip = Membership.can_promote(session, FACTION_A, ranks, RANK_3)
        assert.error_code(skip, FactionErrorCodes.FACTION_PROMOTION_NOT_READY)

        local blocked = Membership.promote(
            session,
            FACTION_A,
            'cmd_promote_too_early',
            RANK_2,
            ranks
        )
        assert.error_code(blocked, FactionErrorCodes.FACTION_PROMOTION_NOT_READY)

        Membership.grant_reputation(
            session,
            FACTION_A,
            'rcpt_promo_rep',
            'STORY',
            'story_gate_01',
            100
        )
        local ready = Membership.can_promote(session, FACTION_A, ranks, RANK_2)
        assert.equal(ready.ok, true)
        assert.equal(ready.value.ready, true)
        assert.equal(ready.value.current_order, 1)
        assert.equal(ready.value.target_order, 2)

        local promoted = Membership.promote(
            session,
            FACTION_A,
            'cmd_promote_ok',
            RANK_2,
            ranks
        )
        assert.equal(promoted.ok, true)
        assert.equal(promoted.value.from_rank_id, RANK_1)
        assert.equal(promoted.value.to_rank_id, RANK_2)
        assert.equal(promoted.value.promoted, true)
        assert.equal(session.records[FACTION_A].rank_id, RANK_2)
        assert.equal(session.records[FACTION_A].promoted, true)
    end),

    case('forbids second active faction and join without candidacy', function()
        local session = Membership.empty_session()
        local first = Membership.begin_candidacy(session, FACTION_A, 'cmd_begin_a')
        assert.equal(first.ok, true)

        local dual = Membership.begin_candidacy(session, FACTION_B, 'cmd_begin_b')
        assert.error_code(dual, FactionErrorCodes.FACTION_ALREADY_JOINED)

        local direct_join = Membership.join_faction(
            Membership.empty_session(),
            FACTION_B,
            'cmd_join_orphan',
            10,
            RANK_1
        )
        assert.error_code(direct_join, FactionErrorCodes.FACTION_NOT_CANDIDATE)

        local joined = Membership.join_faction(session, FACTION_A, 'cmd_join_a', 50, RANK_1)
        assert.equal(joined.ok, true)
        -- already member on A; beginning B still blocked
        local still_dual = Membership.begin_candidacy(session, FACTION_B, 'cmd_begin_b2')
        assert.error_code(still_dual, FactionErrorCodes.FACTION_ALREADY_JOINED)

        local grant_missing = Membership.grant_reputation(
            Membership.empty_session(),
            FACTION_A,
            'rcpt_no_member',
            'QUEST',
            'quest_y',
            10
        )
        assert.error_code(grant_missing, FactionErrorCodes.FACTION_NOT_FOUND)

        local only_candidate = Membership.empty_session()
        Membership.begin_candidacy(only_candidate, FACTION_A, 'cmd_only_cand')
        local grant_candidate = Membership.grant_reputation(
            only_candidate,
            FACTION_A,
            'rcpt_while_candidate',
            'QUEST',
            'quest_y',
            10
        )
        assert.error_code(grant_candidate, FactionErrorCodes.FACTION_NOT_MEMBER)
    end),

    case('query missing faction and invalid joined_at', function()
        local session = Membership.empty_session()
        local missing = Membership.query(session, FACTION_A)
        assert.error_code(missing, FactionErrorCodes.FACTION_NOT_FOUND)

        Membership.begin_candidacy(session, FACTION_A, 'cmd_begin_clock')
        local bad_clock = Membership.join_faction(
            session,
            FACTION_A,
            'cmd_join_clock',
            -1,
            RANK_1
        )
        assert.error_code(bad_clock, FactionErrorCodes.FACTION_ARGUMENT_INVALID)
    end),
}

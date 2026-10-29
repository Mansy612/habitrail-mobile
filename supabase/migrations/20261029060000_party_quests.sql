-- Co-op quests: a shared themed boss goal for a party. Reuses the party goal
-- mechanics (combined XP vs a target + per-member xp_baseline) and adds a
-- quest_id so every member sees the same boss. Rewards are claimed per member
-- on the client. Requires the parties schema (20261029000000_parties.sql).

alter table public.parties
  add column if not exists quest_id text not null default '';

-- Owner starts or changes the co-op quest: stores the quest + its target and
-- rebaselines everyone to "now" (same contribution model as set_party_goal).
-- my_party / create_party / join_party return parties.*, so quest_id flows
-- through them automatically — no change needed there.
create or replace function public.set_party_quest(
  p_id uuid, p_quest text, p_target int, p_week text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties;
begin
  if not exists(select 1 from parties where id = p_id and owner_id = auth.uid())
  then raise exception 'only the owner can set the quest'; end if;
  update parties
    set quest_id = coalesce(p_quest, ''),
        goal_target = greatest(0, p_target),
        goal_week = p_week
    where id = p_id returning * into v_party;
  update party_members m
    set xp_baseline = coalesce((select total_xp from profiles where id = m.user_id), 0)
    where m.party_id = p_id;
  return v_party;
end;
$$;

grant execute on function public.set_party_quest(uuid, text, int, text) to authenticated;

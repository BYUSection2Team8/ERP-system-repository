-- =============================================================================
-- patterns_check.sql — the generated history shows CLEAR demand patterns
-- (migration 024). Read-only. Success = "PATTERN CHECKS PASSED".
--
-- Each pattern is measured by ORDER date with demand_patterns(), the same
-- function behind Reports -> Demand patterns.
-- =============================================================================
do $$
declare
  v_start date := (select value::date from settings where key = 'history_start_date');
  v_end   date := (select value::date from settings where key = 'history_generated_through');
  p jsonb;
  v_sunmon numeric; v_sat numeric;
  v_first text; v_last text;
  v_drg0 numeric; v_drg1 numeric; v_spn0 numeric; v_spn1 numeric;
  v_p3 numeric; v_other numeric;
  v_bf date;
  e jsonb;
begin
  if to_regprocedure('public.demand_patterns(date, date)') is null then
    raise notice 'Skipped: migration 024 is not applied on this database (Practice database 1).';
    return;
  end if;
  if v_start is null or v_end is null then
    raise exception 'No generated history (run seed/002_customers_history.sql first).';
  end if;
  p := public.demand_patterns(v_start, v_end);

  -- Weekday: Sunday/Monday online peak vs quiet Saturday.
  select avg((w->>'per_day')::numeric) filter (where (w->>'dow')::int in (0, 1)),
         avg((w->>'per_day')::numeric) filter (where (w->>'dow')::int = 6)
    into v_sunmon, v_sat from jsonb_array_elements(p->'weekday') w;
  assert v_sunmon >= 1.4 * v_sat, format('Sun/Mon orders per day %s vs Saturday %s (want 1.4x)', v_sunmon, v_sat);

  -- BYU home games lift fall orders, and BYU logos go blue.
  if (p->'game'->>'game_days')::int > 0 then
    assert (p->'game'->>'game_per_day')::numeric >= 1.15 * (p->'game'->>'other_per_day')::numeric,
      format('game days %s orders/day vs other fall days %s', p->'game'->>'game_per_day', p->'game'->>'other_per_day');
    assert (p->'byu_blue'->>'game')::numeric > (p->'byu_blue'->>'other')::numeric,
      format('blue share of BYU logos on game days %s vs other days %s', p->'byu_blue'->>'game', p->'byu_blue'->>'other');
  end if;

  -- Back to school: students order far more in September than in July.
  if exists (select 1 from jsonb_array_elements(p->'monthly') m where m->>'month' like '%-07')
     and exists (select 1 from jsonb_array_elements(p->'monthly') m where m->>'month' like '%-09') then
    assert (select sum((m->>'orders')::int) from jsonb_array_elements(p->'monthly') m
             where m->>'segment' = 'student' and m->>'month' like '%-09')
         >= 2 * (select sum((m->>'orders')::int) from jsonb_array_elements(p->'monthly') m
                  where m->>'segment' = 'student' and m->>'month' like '%-07'),
      'student orders in September at least 2x July';
  end if;

  -- Product life cycle: Dragons gain share, Fidget Spinners lose it (first vs last full month).
  v_first := to_char(date_trunc('month', v_start) + interval '1 month', 'YYYY-MM');
  v_last  := to_char(date_trunc('month', v_end + 1) - interval '1 month', 'YYYY-MM');
  select sum((f->>'units')::numeric) filter (where f->>'family' = 'Dragon' and f->>'month' = v_first)
           / nullif(sum((f->>'units')::numeric) filter (where f->>'month' = v_first), 0),
         sum((f->>'units')::numeric) filter (where f->>'family' = 'Dragon' and f->>'month' = v_last)
           / nullif(sum((f->>'units')::numeric) filter (where f->>'month' = v_last), 0),
         sum((f->>'units')::numeric) filter (where f->>'family' = 'Fidget Spinner' and f->>'month' = v_first)
           / nullif(sum((f->>'units')::numeric) filter (where f->>'month' = v_first), 0),
         sum((f->>'units')::numeric) filter (where f->>'family' = 'Fidget Spinner' and f->>'month' = v_last)
           / nullif(sum((f->>'units')::numeric) filter (where f->>'month' = v_last), 0)
    into v_drg0, v_drg1, v_spn0, v_spn1
    from jsonb_array_elements(p->'families') f;
  assert v_drg1 > v_drg0, format('Dragon share of units %s (%s) -> %s (%s) should rise', v_first, v_drg0, v_last, v_drg1);
  assert v_spn1 < v_spn0, format('Fidget Spinner share %s (%s) -> %s (%s) should fall', v_first, v_spn0, v_last, v_spn1);

  -- Printer 3 overdue for maintenance (mid-Sept to mid-Oct): far more scrap than the others.
  select sum(mo.qty_scrap) filter (where pr.code = 'P2S-3') / nullif(sum(mo.qty_started) filter (where pr.code = 'P2S-3'), 0),
         sum(mo.qty_scrap) filter (where pr.code <> 'P2S-3') / nullif(sum(mo.qty_started) filter (where pr.code <> 'P2S-3'), 0)
    into v_p3, v_other
    from production_orders mo join printers pr on pr.id = mo.printer_id
   where mo.status = 'completed'
     and to_char(mo.finished_at at time zone 'America/Denver', 'MM-DD') between '09-15' and '10-20';
  if v_p3 is not null and v_other is not null then
    assert v_p3 >= 2 * v_other, format('Printer 3 scrap rate %s vs other printers %s in its maintenance window', v_p3, v_other);
  end if;

  -- Thanksgiving week, when it is inside the history.
  v_bf := (select (e2->>'date')::date from jsonb_array_elements(coalesce(p->'events', '[]')) e2 where e2->>'label' = 'Black Friday');
  for e in select * from jsonb_array_elements(coalesce(p->'events', '[]')) loop
    if e->>'label' = 'Black Friday' then
      assert (e->>'orders')::numeric >= 2 * (e->>'november_avg')::numeric, format('Black Friday %s orders vs November avg %s', e->>'orders', e->>'november_avg');
    elsif e->>'label' = 'Thanksgiving' then
      assert (e->>'orders')::numeric < (e->>'november_avg')::numeric, format('Thanksgiving %s orders vs November avg %s', e->>'orders', e->>'november_avg');
    end if;
  end loop;

  raise notice 'Patterns: Sun/Mon %/day vs Sat %/day; game days % vs %; Dragon share % -> %; Spinner share % -> %; Printer 3 scrap % vs %; Black Friday %.',
    round(v_sunmon, 1), round(v_sat, 1), p->'game'->>'game_per_day', p->'game'->>'other_per_day',
    round(v_drg0, 3), round(v_drg1, 3), round(v_spn0, 3), round(v_spn1, 3), round(v_p3, 3), round(v_other, 3),
    coalesce(v_bf::text, 'not in the history yet');
end $$;

select 'PATTERN CHECKS PASSED' as result;

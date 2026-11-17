-- =====================================================================
-- Streak-Duell – Datenbank-Vorlage für Supabase
-- Komplett in Supabase > SQL Editor einfügen und einmal auf "Run" drücken.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Hilfsfunktion: heutiges Datum in Berlin ----------
create or replace function public.berlin_today() returns date
language sql stable as $$
  select (now() at time zone 'Europe/Berlin')::date;
$$;

-- ---------- Spieler (max. 2) ----------
create table if not exists public.players (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 30),
  created_at timestamptz not null default now()
);

create or replace function public.is_player() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.players where id = auth.uid());
$$;

create or replace function public.join_game(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Nicht eingeloggt'; end if;
  if char_length(coalesce(trim(p_name), '')) = 0 then raise exception 'Name fehlt'; end if;
  lock table public.players in exclusive mode;
  if exists (select 1 from public.players where id = auth.uid()) then
    update public.players set name = trim(p_name) where id = auth.uid();
    return;
  end if;
  if (select count(*) from public.players) >= 2 then
    raise exception 'Das Spiel ist schon voll (2 Spieler).';
  end if;
  insert into public.players (id, name) values (auth.uid(), trim(p_name));
end $$;

-- ---------- Aufgaben / Challenges ----------
-- repeat: daily = jeden Tag, weekdays = bestimmte Wochentage (1=Mo … 7=So),
--         once = nur an start_date, interval = alle every_days Tage ab start_date
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.players(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  points int not null check (points between 1 and 100),
  proof_hint text check (char_length(proof_hint) <= 120),
  repeat text not null check (repeat in ('daily','weekdays','once','interval')),
  weekdays int[],
  start_date date not null,
  every_days int check (every_days between 1 and 365),
  due_time time,
  approved boolean not null default false,
  approved_by uuid references public.players(id),
  approved_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  check (repeat <> 'weekdays' or (weekdays is not null and cardinality(weekdays) > 0
         and weekdays <@ array[1,2,3,4,5,6,7])),
  check (repeat <> 'interval' or every_days is not null)
);

create or replace function public.task_due_on(t public.tasks, d date) returns boolean
language sql stable as $$
  select t.approved
     and t.archived_at is null
     and d >= t.start_date
     and case t.repeat
           when 'daily'    then true
           when 'weekdays' then extract(isodow from d)::int = any (t.weekdays)
           when 'once'     then d = t.start_date
           when 'interval' then ((d - t.start_date) % t.every_days) = 0
         end;
$$;

create or replace function public.tasks_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  new.owner := auth.uid();
  new.approved := false;
  new.approved_by := null;
  new.approved_at := null;
  new.archived_at := null;
  new.created_at := now();
  if new.start_date is null then new.start_date := public.berlin_today(); end if;
  if new.start_date < public.berlin_today() then new.start_date := public.berlin_today(); end if;
  return new;
end $$;
drop trigger if exists tasks_bi on public.tasks;
create trigger tasks_bi before insert on public.tasks
  for each row execute function public.tasks_before_insert();

-- Die andere Person bestätigt (ok=true) oder lehnt ab (ok=false → wird gelöscht)
create or replace function public.decide_task(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  select * into t from public.tasks where id = p_id for update;
  if not found then raise exception 'Aufgabe nicht gefunden'; end if;
  if t.owner = auth.uid() then raise exception 'Eigene Aufgaben bestätigt die andere Person'; end if;
  if t.approved then raise exception 'Schon bestätigt'; end if;
  if t.archived_at is not null then raise exception 'Challenge wurde beendet'; end if;
  if p_ok then
    update public.tasks set approved = true, approved_by = auth.uid(), approved_at = now() where id = p_id;
  else
    delete from public.tasks where id = p_id;
  end if;
end $$;

-- Eigene Aufgabe beenden (bleibt für die Statistik erhalten)
create or replace function public.archive_task(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.tasks set archived_at = now()
   where id = p_id and owner = auth.uid() and archived_at is null;
  if not found then raise exception 'Nicht möglich'; end if;
end $$;

-- ---------- Beweise ----------
create table if not exists public.proofs (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null references public.players(id) on delete cascade,
  for_date date not null,
  created_at timestamptz not null default now(),
  points int not null,
  lat double precision,
  lng double precision,
  accuracy double precision,
  photo_path text,
  late boolean not null default false,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.players(id),
  reviewed_at timestamptz
);
alter table public.proofs add column if not exists late boolean not null default false;
create unique index if not exists proofs_photo_once on public.proofs (photo_path) where photo_path is not null;
create unique index if not exists proofs_one_per_day
  on public.proofs (task_id, for_date) where status <> 'rejected';

create or replace function public.proofs_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  select * into t from public.tasks where id = new.task_id;
  if not found then raise exception 'Aufgabe nicht gefunden'; end if;
  if t.owner <> auth.uid() then raise exception 'Nicht deine Aufgabe'; end if;
  -- Zeitstempel kommt IMMER vom Server, nie vom Handy
  new.user_id := auth.uid();
  new.created_at := now();
  new.for_date := public.berlin_today();
  if not public.task_due_on(t, new.for_date) then raise exception 'Diese Aufgabe ist heute nicht dran'; end if;
  new.points := t.points;
  new.status := 'pending';
  new.reviewed_by := null;
  new.reviewed_at := null;
  if new.photo_path is null or new.photo_path not like (auth.uid()::text || '/%') then
    raise exception 'Foto fehlt';
  end if;
  -- Foto muss wirklich gerade eben hochgeladen worden sein
  if not exists (select 1 from storage.objects o
                  where o.bucket_id = 'proofs' and o.name = new.photo_path
                    and o.created_at > now() - interval '10 minutes') then
    raise exception 'Foto nicht gefunden oder zu alt – bitte neu aufnehmen';
  end if;
  new.late := t.due_time is not null and (now() at time zone 'Europe/Berlin')::time > t.due_time;
  if new.lat is null or new.lng is null then raise exception 'Standort fehlt'; end if;
  return new;
end $$;
drop trigger if exists proofs_bi on public.proofs;
create trigger proofs_bi before insert on public.proofs
  for each row execute function public.proofs_before_insert();

create or replace function public.review_proof(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare p public.proofs;
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  select * into p from public.proofs where id = p_id for update;
  if not found then raise exception 'Beweis nicht gefunden'; end if;
  if p.user_id = auth.uid() then raise exception 'Eigene Beweise prüft die andere Person'; end if;
  if p.status <> 'pending' then raise exception 'Schon geprüft'; end if;
  update public.proofs
     set status = case when p_ok then 'approved' else 'rejected' end,
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id;
end $$;

-- Fotos: 3 Tage nach der Prüfung löschen (die App räumt beim Öffnen auf)
create or replace function public.photos_due_for_deletion()
returns table (id uuid, photo_path text)
language sql stable security definer set search_path = public as $$
  select p.id, p.photo_path from public.proofs p
   where public.is_player()
     and p.photo_path is not null
     and ((p.reviewed_at is not null and p.reviewed_at < now() - interval '3 days')
          or (p.reviewed_at is null and p.created_at < now() - interval '7 days'));
$$;

create or replace function public.clear_photos(p_ids uuid[]) returns void
language sql security definer set search_path = public as $$
  update public.proofs set photo_path = null
   where public.is_player()
     and id = any (p_ids)
     and ((reviewed_at is not null and reviewed_at < now() - interval '3 days')
          or (reviewed_at is null and created_at < now() - interval '7 days'));
$$;

-- ---------- Belohnungen ----------
create table if not exists public.rewards (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.players(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  cost int not null check (cost between 1 and 100000),
  approved boolean not null default false,
  approved_by uuid references public.players(id),
  archived_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.rewards_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  new.owner := auth.uid();
  new.approved := false;
  new.approved_by := null;
  new.archived_at := null;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists rewards_bi on public.rewards;
create trigger rewards_bi before insert on public.rewards
  for each row execute function public.rewards_before_insert();

create or replace function public.decide_reward(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.rewards;
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  select * into r from public.rewards where id = p_id for update;
  if not found then raise exception 'Belohnung nicht gefunden'; end if;
  if r.owner = auth.uid() then raise exception 'Den Preis bestätigt die andere Person'; end if;
  if r.approved then raise exception 'Schon bestätigt'; end if;
  if p_ok then
    update public.rewards set approved = true, approved_by = auth.uid() where id = p_id;
  else
    delete from public.rewards where id = p_id;
  end if;
end $$;

create or replace function public.archive_reward(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.rewards set archived_at = now()
   where id = p_id and owner = auth.uid() and archived_at is null;
  if not found then raise exception 'Nicht möglich'; end if;
end $$;

-- ---------- Einlösungen ----------
create table if not exists public.redemptions (
  id uuid primary key default gen_random_uuid(),
  reward_id uuid not null references public.rewards(id) on delete cascade,
  user_id uuid not null references public.players(id) on delete cascade,
  title text not null,
  cost int not null,
  created_at timestamptz not null default now(),
  fulfilled boolean not null default false,
  fulfilled_at timestamptz
);

create or replace function public.balance_of(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when public.is_player() then
           coalesce((select sum(points) from public.proofs where user_id = p_user and status = 'approved'), 0)
         - coalesce((select sum(cost) from public.redemptions where user_id = p_user), 0)
         end;
$$;

create or replace function public.redeem(p_reward uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.rewards;
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
  select * into r from public.rewards where id = p_reward;
  if not found or r.owner <> auth.uid() or not r.approved or r.archived_at is not null then
    raise exception 'Belohnung nicht verfügbar';
  end if;
  if public.balance_of(auth.uid()) < r.cost then raise exception 'Nicht genug Punkte'; end if;
  insert into public.redemptions (reward_id, user_id, title, cost) values (r.id, auth.uid(), r.title, r.cost);
end $$;

-- Die andere Person hakt ab, dass die Belohnung wirklich eingelöst wurde
create or replace function public.fulfill_redemption(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  update public.redemptions set fulfilled = true, fulfilled_at = now()
   where id = p_id and user_id <> auth.uid() and not fulfilled;
  if not found then raise exception 'Nicht möglich'; end if;
end $$;

-- ---------- Pause-Tage (Ferien, krank) ----------
create table if not exists public.pause_days (
  user_id uuid not null references public.players(id) on delete cascade,
  day date not null,
  approved boolean not null default false,
  approved_by uuid references public.players(id),
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.pause_days add column if not exists approved boolean not null default false;
alter table public.pause_days add column if not exists approved_by uuid references public.players(id);

create or replace function public.pause_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  new.user_id := auth.uid();
  new.created_at := now();
  new.approved := false;
  new.approved_by := null;
  -- nur heute oder in der Zukunft, damit man einen verpassten Tag nicht nachträglich rettet
  if new.day < public.berlin_today() then raise exception 'Pause-Tage nur für heute oder später'; end if;
  return new;
end $$;
drop trigger if exists pause_bi on public.pause_days;
create trigger pause_bi before insert on public.pause_days
  for each row execute function public.pause_before_insert();

-- Pause-Tage zählen erst, wenn die andere Person sie bestätigt hat
create or replace function public.decide_pause(p_user uuid, p_day date, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_player() then raise exception 'Kein Spieler'; end if;
  if p_user = auth.uid() then raise exception 'Eigene Pause-Tage bestätigt die andere Person'; end if;
  if p_ok then
    update public.pause_days set approved = true, approved_by = auth.uid()
     where user_id = p_user and day = p_day and not approved;
  else
    delete from public.pause_days where user_id = p_user and day = p_day and not approved;
  end if;
  if not found then raise exception 'Nicht möglich'; end if;
end $$;

-- ---------- Zugriffsschutz (Row Level Security) ----------
alter table public.players     enable row level security;
alter table public.tasks       enable row level security;
alter table public.proofs      enable row level security;
alter table public.rewards     enable row level security;
alter table public.redemptions enable row level security;
alter table public.pause_days  enable row level security;

drop policy if exists players_read on public.players;
create policy players_read on public.players for select to authenticated using (public.is_player());

drop policy if exists tasks_read on public.tasks;
create policy tasks_read on public.tasks for select to authenticated using (public.is_player());
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check (public.is_player());

drop policy if exists proofs_read on public.proofs;
create policy proofs_read on public.proofs for select to authenticated using (public.is_player());
drop policy if exists proofs_insert on public.proofs;
create policy proofs_insert on public.proofs for insert to authenticated with check (public.is_player());

drop policy if exists rewards_read on public.rewards;
create policy rewards_read on public.rewards for select to authenticated using (public.is_player());
drop policy if exists rewards_insert on public.rewards;
create policy rewards_insert on public.rewards for insert to authenticated with check (public.is_player());

drop policy if exists redemptions_read on public.redemptions;
create policy redemptions_read on public.redemptions for select to authenticated using (public.is_player());

drop policy if exists pause_read on public.pause_days;
create policy pause_read on public.pause_days for select to authenticated using (public.is_player());
drop policy if exists pause_insert on public.pause_days;
create policy pause_insert on public.pause_days for insert to authenticated with check (public.is_player());
drop policy if exists pause_delete on public.pause_days;
create policy pause_delete on public.pause_days for delete to authenticated
  using (user_id = auth.uid() and day >= public.berlin_today());

-- Tabellen-Rechte (neue Supabase-Projekte geben Tabellen nicht mehr automatisch frei)
grant usage on schema public to authenticated;
revoke all on public.players, public.tasks, public.proofs, public.rewards, public.redemptions, public.pause_days from authenticated;
grant select on public.players, public.tasks, public.proofs, public.rewards, public.redemptions, public.pause_days to authenticated;
grant insert on public.tasks, public.proofs, public.rewards, public.pause_days to authenticated;
grant delete on public.pause_days to authenticated;

-- Für nicht eingeloggte Besucher ist alles gesperrt
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;

-- ---------- Foto-Speicher ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs', 'proofs', false, 3145728, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists proofs_upload on storage.objects;
create policy proofs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'proofs' and public.is_player()
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists proofs_view on storage.objects;
create policy proofs_view on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and public.is_player());

drop policy if exists proofs_remove on storage.objects;
create policy proofs_remove on storage.objects for delete to authenticated
  using (bucket_id = 'proofs' and public.is_player() and (
    -- eigenes Foto, das (noch) zu keinem Beweis gehört (fehlgeschlagenes Senden)
    ((storage.foldername(name))[1] = auth.uid()::text
      and not exists (select 1 from public.proofs p where p.photo_path = name))
    -- oder Aufräumen: geprüft vor mehr als 3 Tagen / ungeprüft älter als 7 Tage
    or exists (select 1 from public.proofs p where p.photo_path = name and (
         (p.reviewed_at is not null and p.reviewed_at < now() - interval '3 days')
         or (p.reviewed_at is null and p.created_at < now() - interval '7 days')))
  ));

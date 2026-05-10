-- Nearby telemetry tables
-- Run this in Supabase SQL Editor: https://supabase.com/dashboard/project/tsixhtjsmwqadwgrawbs/sql

-- Events table: one row per telemetry ping
create table if not exists nearby_events (
  id bigint generated always as identity primary key,
  device_id text not null,          -- anonymous hash, not the real Find My ID
  event text not null,              -- 'setup_complete', 'check', 'alert_sent', 'intro_sent', 'app_launch'
  friend_count int,                 -- how many friends tracked
  radius_meters int,
  alerts_sent int default 0,        -- alerts fired this check cycle
  intros_sent int default 0,        -- intro alerts fired this check cycle
  friends_nearby int default 0,     -- how many friends were within radius
  app_version text,
  created_at timestamptz default now()
);

-- Daily active users rollup (for dashboards)
create table if not exists nearby_daily_active (
  id bigint generated always as identity primary key,
  device_id text not null,
  date date not null default current_date,
  checks int default 0,
  alerts int default 0,
  intros int default 0,
  unique(device_id, date)
);

-- Indexes
create index if not exists idx_nearby_events_created on nearby_events(created_at);
create index if not exists idx_nearby_events_device on nearby_events(device_id);
create index if not exists idx_nearby_events_event on nearby_events(event);
create index if not exists idx_nearby_daily_date on nearby_daily_active(date);

-- RLS: allow anonymous inserts (anon key), no reads from client
alter table nearby_events enable row level security;
alter table nearby_daily_active enable row level security;

create policy "Allow anonymous inserts" on nearby_events
  for insert to anon with check (true);

create policy "Allow anonymous upserts" on nearby_daily_active
  for insert to anon with check (true);

-- Allow update for the upsert (ON CONFLICT DO UPDATE)
create policy "Allow anonymous updates" on nearby_daily_active
  for update to anon using (true) with check (true);

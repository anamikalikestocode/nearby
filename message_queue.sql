-- Message queue for iMessage sending
create table if not exists message_queue (
    id uuid primary key default gen_random_uuid(),
    recipient_phone text not null,
    message text not null,
    status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    device_id text not null,
    error text
);

-- Fast polling index: only scan pending messages
create index if not exists idx_mq_pending on message_queue (status, created_at) where status = 'pending';

-- Auto-clean old messages after 7 days (optional, keeps table small)
-- Can be run via pg_cron if needed

-- RLS
alter table message_queue enable row level security;

-- Anon can INSERT (user Macs queue messages)
create policy "anon_insert" on message_queue for insert to anon with check (true);

-- Anon CANNOT read (protects phone numbers)
create policy "anon_no_select" on message_queue for select to anon using (false);

-- Service role can read + update (Anamika's poller)
create policy "service_select" on message_queue for select to service_role using (true);
create policy "service_update" on message_queue for update to service_role using (true) with check (true);

-- =====================================================================
-- FLEX UP — initial schema for Supabase (Postgres 15+)
-- Accounts, videos, comments, likes, saves, follows, blocks, challenges,
-- reports, notifications + Row Level Security, counters, rate limits,
-- feed/search RPCs and Storage buckets/policies.
-- Apply with:  supabase db push   (or paste into SQL editor)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
do $$ begin
  create type public.video_visibility as enum ('everyone', 'followers', 'only_me');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.video_mood as enum ('funny', 'calm', 'energetic', 'inspiring', 'cozy');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.report_target as enum ('video', 'comment', 'user');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.report_status as enum ('open', 'reviewing', 'resolved', 'rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.activity_kind as enum ('like', 'comment', 'follow', 'mention', 'challenge', 'react', 'system');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  username         text not null unique
                   check (username ~ '^[a-z0-9_][a-z0-9_.]{1,22}[a-z0-9_]$'),
  display_name     text not null check (char_length(display_name) between 1 and 40),
  bio              text not null default '' check (char_length(bio) <= 160),
  avatar_url       text,
  avatar_colors    text[] not null default array['#8A2BFF', '#19E3D1'],
  followers_count  integer not null default 0 check (followers_count >= 0),
  following_count  integer not null default 0 check (following_count >= 0),
  likes_count      bigint  not null default 0 check (likes_count >= 0),
  posts_count      integer not null default 0 check (posts_count >= 0),
  is_private       boolean not null default false,
  is_verified      boolean not null default false,
  created_at       timestamptz not null default now()
);

create table if not exists public.videos (
  id              uuid primary key default gen_random_uuid(),
  author_id       uuid not null references public.profiles (id) on delete cascade,
  caption         text not null default '' check (char_length(caption) <= 300),
  hashtags        text[] not null default '{}' check (cardinality(hashtags) <= 11),
  music_title     text not null default 'Оригинальный звук' check (char_length(music_title) <= 120),
  mood            public.video_mood,
  duration        real check (duration > 0 and duration <= 61),
  storage_path    text not null,
  video_url       text not null,
  hls_url         text,              -- filled by an optional transcoding pipeline (not included)
  thumbnail_url   text,
  likes_count     integer not null default 0 check (likes_count >= 0),
  comments_count  integer not null default 0 check (comments_count >= 0),
  saves_count     integer not null default 0 check (saves_count >= 0),
  shares_count    integer not null default 0 check (shares_count >= 0),
  views_count     integer not null default 0 check (views_count >= 0),
  visibility      public.video_visibility not null default 'everyone',
  challenge_tag   text,
  reply_to        uuid references public.videos (id) on delete set null,
  is_hidden       boolean not null default false, -- set by moderators
  created_at      timestamptz not null default now(),
  constraint storage_path_owned check (split_part(storage_path, '/', 1) = author_id::text)
);
create index if not exists videos_created_idx  on public.videos (created_at desc);
create index if not exists videos_author_idx   on public.videos (author_id, created_at desc);
create index if not exists videos_tags_idx     on public.videos using gin (hashtags);
create index if not exists videos_reply_idx    on public.videos (reply_to) where reply_to is not null;
create index if not exists videos_challenge_idx on public.videos (challenge_tag) where challenge_tag is not null;

create table if not exists public.likes (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  video_id   uuid not null references public.videos (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);
create index if not exists likes_video_idx on public.likes (video_id);

create table if not exists public.saves (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  video_id   uuid not null references public.videos (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

create table if not exists public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on public.follows (followee_id);

create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  video_id    uuid not null references public.videos (id) on delete cascade,
  author_id   uuid not null,
  body        text not null check (char_length(btrim(body)) between 1 and 500),
  likes_count integer not null default 0,
  created_at  timestamptz not null default now(),
  constraint comments_author_id_fkey foreign key (author_id) references public.profiles (id) on delete cascade
);
create index if not exists comments_video_idx on public.comments (video_id, created_at desc);
create index if not exists comments_author_idx on public.comments (author_id, created_at desc);

create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists blocks_blocked_idx on public.blocks (blocked_id);

create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  target_kind public.report_target not null,
  target_id   uuid not null,
  reason      text not null check (reason in ('spam','harassment','violence','nudity','hate','misinformation','copyright','other')),
  details     text not null default '' check (char_length(details) <= 500),
  status      public.report_status not null default 'open',
  created_at  timestamptz not null default now(),
  unique (reporter_id, target_kind, target_id)
);

create table if not exists public.challenges (
  id         uuid primary key default gen_random_uuid(),
  tag        text not null check (tag ~ '^[[:alnum:]_]{1,40}$'),
  title      text not null,
  details    text not null default '',
  emoji      text not null default '🏆',
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  check (ends_at > starts_at),
  unique (tag, starts_at)
);

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  kind       public.activity_kind not null,
  actor_id   uuid references public.profiles (id) on delete cascade,
  video_id   uuid references public.videos (id) on delete cascade,
  body       text not null,
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

create table if not exists public.video_views (
  user_id   uuid not null references public.profiles (id) on delete cascade,
  video_id  uuid not null references public.videos (id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select a is not null and b is not null and exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

create or replace function public.is_following(follower uuid, followee uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select follower is not null and exists (
    select 1 from public.follows where follower_id = follower and followee_id = followee
  );
$$;

-- Single source of truth for "may the current user see this video?" (used by RLS and RPCs).
create or replace function public.can_view_video(v_author uuid, v_visibility public.video_visibility, v_hidden boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when v_author = auth.uid() then true
    when v_hidden then false
    when public.is_blocked_between(auth.uid(), v_author) then false
    when (select is_private from public.profiles where id = v_author)
         and not public.is_following(auth.uid(), v_author) then false
    when v_visibility = 'everyone' then true
    when v_visibility = 'followers' then public.is_following(auth.uid(), v_author)
    else false
  end;
$$;

create or replace function public.mood_tags(m public.video_mood)
returns text[] language sql immutable as $$
  select case m
    when 'funny'     then array['юмор','смешно','прикол','мем','funny','comedy','лол']
    when 'calm'      then array['спокойно','релакс','медитация','природа','asmr','calm','lofi']
    when 'energetic' then array['энергия','спорт','танцы','драйв','dance','workout','трен']
    when 'inspiring' then array['мотивация','вдохновение','искусство','art','цели','космос']
    when 'cozy'      then array['уют','кофе','дом','осень','готовка','книги','cozy']
  end;
$$;

-- Sliding-window rate limit. Raises an error whose message starts with "rate_limited".
create or replace function public.enforce_rate_limit(action text, recent_count bigint, max_count integer)
returns void language plpgsql as $$
begin
  if recent_count >= max_count then
    raise exception 'rate_limited: % (max % per window)', action, max_count using errcode = 'P0429';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- New user → profile
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted text := lower(coalesce(new.raw_user_meta_data ->> 'username', ''));
  final  text;
begin
  wanted := regexp_replace(wanted, '[^a-z0-9_.]', '', 'g');
  if wanted !~ '^[a-z0-9_][a-z0-9_.]{1,22}[a-z0-9_]$'
     or exists (select 1 from public.profiles where username = wanted) then
    final := 'user_' || substr(replace(new.id::text, '-', ''), 1, 10);
  else
    final := wanted;
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, final, coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), final));
  insert into public.notifications (user_id, kind, body)
  values (new.id, 'system', 'Добро пожаловать во FLEX UP! Лови момент. Задавай тренд.');
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Guards (rate limits, integrity) — BEFORE triggers
-- ---------------------------------------------------------------------
create or replace function public.guard_video_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_rate_limit('publish',
    (select count(*) from public.videos where author_id = new.author_id and created_at > now() - interval '1 hour'), 10);
  -- Server is the authority for derived/counter fields.
  new.likes_count := 0; new.comments_count := 0; new.saves_count := 0;
  new.shares_count := 0; new.views_count := 0; new.is_hidden := false; new.created_at := now();
  new.hashtags := (select coalesce(array_agg(distinct lower(t)), '{}') from unnest(new.hashtags) t where t ~ '^[[:alnum:]_]{1,40}$');
  if new.challenge_tag is not null then new.challenge_tag := lower(new.challenge_tag); end if;
  if new.reply_to is not null and not exists (
      select 1 from public.videos v where v.id = new.reply_to
        and public.can_view_video(v.author_id, v.visibility, v.is_hidden)) then
    raise exception 'reply_to video is not visible' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists videos_guard on public.videos;
create trigger videos_guard before insert on public.videos for each row execute function public.guard_video_insert();

-- Authors may edit only caption-like fields; counters are server-owned.
create or replace function public.guard_video_update()
returns trigger language plpgsql as $$
begin
  if current_setting('flexup.internal', true) = 'on' then return new; end if;
  new.author_id := old.author_id; new.storage_path := old.storage_path; new.video_url := old.video_url;
  new.likes_count := old.likes_count; new.comments_count := old.comments_count; new.saves_count := old.saves_count;
  new.shares_count := old.shares_count; new.views_count := old.views_count; new.created_at := old.created_at;
  new.is_hidden := old.is_hidden; new.hls_url := old.hls_url;
  return new;
end $$;

drop trigger if exists videos_guard_update on public.videos;
create trigger videos_guard_update before update on public.videos for each row execute function public.guard_video_update();

create or replace function public.guard_comment_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare v record;
begin
  perform public.enforce_rate_limit('comment',
    (select count(*) from public.comments where author_id = new.author_id and created_at > now() - interval '1 minute'), 10);
  select author_id, visibility, is_hidden into v from public.videos where id = new.video_id;
  if public.is_blocked_between(new.author_id, v.author_id) then
    raise exception 'blocked' using errcode = '42501';
  end if;
  new.body := btrim(new.body); new.likes_count := 0; new.created_at := now();
  return new;
end $$;

drop trigger if exists comments_guard on public.comments;
create trigger comments_guard before insert on public.comments for each row execute function public.guard_comment_insert();

create or replace function public.guard_follow_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_rate_limit('follow',
    (select count(*) from public.follows where follower_id = new.follower_id and created_at > now() - interval '1 minute'), 60);
  if public.is_blocked_between(new.follower_id, new.followee_id) then
    raise exception 'blocked' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists follows_guard on public.follows;
create trigger follows_guard before insert on public.follows for each row execute function public.guard_follow_insert();

create or replace function public.guard_like_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_rate_limit('like',
    (select count(*) from public.likes where user_id = new.user_id and created_at > now() - interval '1 minute'), 120);
  return new;
end $$;

drop trigger if exists likes_guard on public.likes;
create trigger likes_guard before insert on public.likes for each row execute function public.guard_like_insert();

create or replace function public.guard_report_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_rate_limit('report',
    (select count(*) from public.reports where reporter_id = new.reporter_id and created_at > now() - interval '1 hour'), 20);
  new.status := 'open'; new.created_at := now();
  return new;
end $$;

drop trigger if exists reports_guard on public.reports;
create trigger reports_guard before insert on public.reports for each row execute function public.guard_report_insert();

-- Blocking removes follow relations in both directions.
create or replace function public.after_block()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.follows
   where (follower_id = new.blocker_id and followee_id = new.blocked_id)
      or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end $$;

drop trigger if exists blocks_after on public.blocks;
create trigger blocks_after after insert on public.blocks for each row execute function public.after_block();

-- ---------------------------------------------------------------------
-- Counters + notifications — AFTER triggers (security definer: bypass RLS)
-- ---------------------------------------------------------------------
create or replace function public.notify(target uuid, k public.activity_kind, actor uuid, vid uuid, txt text)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, kind, actor_id, video_id, body)
  select target, k, actor, vid, txt
  where target is not null and target <> actor and not public.is_blocked_between(target, actor);
$$;

create or replace function public.on_like_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  perform set_config('flexup.internal', 'on', true);
  if tg_op = 'INSERT' then
    update public.videos set likes_count = likes_count + 1 where id = new.video_id returning author_id into owner;
    update public.profiles set likes_count = likes_count + 1 where id = owner;
    perform public.notify(owner, 'like', new.user_id, new.video_id, 'оценил(а) твой ролик');
  else
    update public.videos set likes_count = greatest(likes_count - 1, 0) where id = old.video_id returning author_id into owner;
    update public.profiles set likes_count = greatest(likes_count - 1, 0) where id = owner;
  end if;
  perform set_config('flexup.internal', 'off', true);
  return null;
end $$;

drop trigger if exists likes_count on public.likes;
create trigger likes_count after insert or delete on public.likes for each row execute function public.on_like_change();

create or replace function public.on_save_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform set_config('flexup.internal', 'on', true);
  if tg_op = 'INSERT' then
    update public.videos set saves_count = saves_count + 1 where id = new.video_id;
  else
    update public.videos set saves_count = greatest(saves_count - 1, 0) where id = old.video_id;
  end if;
  perform set_config('flexup.internal', 'off', true);
  return null;
end $$;

drop trigger if exists saves_count on public.saves;
create trigger saves_count after insert or delete on public.saves for each row execute function public.on_save_change();

create or replace function public.on_comment_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  perform set_config('flexup.internal', 'on', true);
  if tg_op = 'INSERT' then
    update public.videos set comments_count = comments_count + 1 where id = new.video_id returning author_id into owner;
    perform public.notify(owner, 'comment', new.author_id, new.video_id, 'прокомментировал(а): «' || left(new.body, 60) || '»');
  else
    update public.videos set comments_count = greatest(comments_count - 1, 0) where id = old.video_id;
  end if;
  perform set_config('flexup.internal', 'off', true);
  return null;
end $$;

drop trigger if exists comments_count on public.comments;
create trigger comments_count after insert or delete on public.comments for each row execute function public.on_comment_change();

create or replace function public.on_follow_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set followers_count = followers_count + 1 where id = new.followee_id;
    update public.profiles set following_count = following_count + 1 where id = new.follower_id;
    perform public.notify(new.followee_id, 'follow', new.follower_id, null, 'подписался(ась) на тебя');
  else
    update public.profiles set followers_count = greatest(followers_count - 1, 0) where id = old.followee_id;
    update public.profiles set following_count = greatest(following_count - 1, 0) where id = old.follower_id;
  end if;
  return null;
end $$;

drop trigger if exists follows_count on public.follows;
create trigger follows_count after insert or delete on public.follows for each row execute function public.on_follow_change();

create or replace function public.on_video_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare original_owner uuid;
begin
  if tg_op = 'INSERT' then
    update public.profiles set posts_count = posts_count + 1 where id = new.author_id;
    if new.reply_to is not null then
      select author_id into original_owner from public.videos where id = new.reply_to;
      perform public.notify(original_owner, 'react', new.author_id, new.id, 'записал(а) DUO REACT на твой ролик');
    end if;
  else
    update public.profiles set posts_count = greatest(posts_count - 1, 0),
                               likes_count = greatest(likes_count - old.likes_count, 0)
     where id = old.author_id;
  end if;
  return null;
end $$;

drop trigger if exists videos_count on public.videos;
create trigger videos_count after insert or delete on public.videos for each row execute function public.on_video_change();

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.videos        enable row level security;
alter table public.likes         enable row level security;
alter table public.saves         enable row level security;
alter table public.follows       enable row level security;
alter table public.comments      enable row level security;
alter table public.blocks        enable row level security;
alter table public.reports       enable row level security;
alter table public.challenges    enable row level security;
alter table public.notifications enable row level security;
alter table public.video_views   enable row level security;

-- profiles: public read; owner updates (counters protected by column grants below)
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- videos
drop policy if exists videos_read on public.videos;
create policy videos_read on public.videos for select using (public.can_view_video(author_id, visibility, is_hidden));
drop policy if exists videos_insert_own on public.videos;
create policy videos_insert_own on public.videos for insert to authenticated with check (author_id = auth.uid());
drop policy if exists videos_update_own on public.videos;
create policy videos_update_own on public.videos for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists videos_delete_own on public.videos;
create policy videos_delete_own on public.videos for delete to authenticated using (author_id = auth.uid());

-- likes / saves: private to their owner
drop policy if exists likes_own on public.likes;
create policy likes_own on public.likes for select to authenticated using (user_id = auth.uid());
drop policy if exists likes_insert on public.likes;
create policy likes_insert on public.likes for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.videos v where v.id = video_id)); -- videos RLS applies inside
drop policy if exists likes_delete on public.likes;
create policy likes_delete on public.likes for delete to authenticated using (user_id = auth.uid());

drop policy if exists saves_own on public.saves;
create policy saves_own on public.saves for select to authenticated using (user_id = auth.uid());
drop policy if exists saves_insert on public.saves;
create policy saves_insert on public.saves for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.videos v where v.id = video_id));
drop policy if exists saves_delete on public.saves;
create policy saves_delete on public.saves for delete to authenticated using (user_id = auth.uid());

-- follows: social graph is public; you can only create/delete your own edges
drop policy if exists follows_read on public.follows;
create policy follows_read on public.follows for select using (true);
drop policy if exists follows_insert on public.follows;
create policy follows_insert on public.follows for insert to authenticated with check (follower_id = auth.uid());
drop policy if exists follows_delete on public.follows;
create policy follows_delete on public.follows for delete to authenticated using (follower_id = auth.uid());

-- comments: visible when the video is visible and nobody blocked anybody
drop policy if exists comments_read on public.comments;
create policy comments_read on public.comments for select using (
  not public.is_blocked_between(auth.uid(), author_id)
  and exists (select 1 from public.videos v where v.id = video_id));
drop policy if exists comments_insert on public.comments;
create policy comments_insert on public.comments for insert to authenticated with check (
  author_id = auth.uid() and exists (select 1 from public.videos v where v.id = video_id));
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments for delete to authenticated using (
  author_id = auth.uid()
  or exists (select 1 from public.videos v where v.id = video_id and v.author_id = auth.uid()));

-- blocks: only your own list
drop policy if exists blocks_own on public.blocks;
create policy blocks_own on public.blocks for select to authenticated using (blocker_id = auth.uid());
drop policy if exists blocks_insert on public.blocks;
create policy blocks_insert on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
drop policy if exists blocks_delete on public.blocks;
create policy blocks_delete on public.blocks for delete to authenticated using (blocker_id = auth.uid());

-- reports: write-only for users (moderators use the service role / dashboard)
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated with check (reporter_id = auth.uid());

-- challenges: public read, managed by service role
drop policy if exists challenges_read on public.challenges;
create policy challenges_read on public.challenges for select using (true);

-- notifications: only the recipient
drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists views_own on public.video_views;
create policy views_own on public.video_views for select to authenticated using (user_id = auth.uid());

-- Column-level protection: users may only update these profile columns.
revoke update on public.profiles from anon, authenticated;
grant update (username, display_name, bio, avatar_url, avatar_colors, is_private) on public.profiles to authenticated;
revoke update on public.notifications from anon, authenticated;
grant update (is_read) on public.notifications to authenticated;
revoke update on public.videos from anon, authenticated;
grant update (caption, visibility, music_title, mood) on public.videos to authenticated;

-- ---------------------------------------------------------------------
-- Feed / search RPCs (SECURITY INVOKER → RLS still applies)
-- ---------------------------------------------------------------------
create or replace function public.feed_row(v public.videos)
returns jsonb language sql stable set search_path = public as $$
  select to_jsonb(v) - 'storage_path' - 'is_hidden'
    || jsonb_build_object(
         'author', (select to_jsonb(p) from public.profiles p where p.id = v.author_id),
         'is_liked', exists (select 1 from public.likes l where l.video_id = v.id and l.user_id = auth.uid()),
         'is_saved', exists (select 1 from public.saves s where s.video_id = v.id and s.user_id = auth.uid()),
         'is_following', public.is_following(auth.uid(), v.author_id));
$$;

-- Transparent rule-based ranking (NOT machine learning). Mirrors RecommendationEngine in FlexCore:
-- follow bonus + mood match + freshness (half-life 48h) + engagement − already seen, then author diversity.
create or replace function public.feed_for_you(p_limit integer default 30, p_mood text default null, p_hidden_tags text[] default '{}')
returns setof jsonb language sql stable set search_path = public as $$
  with scored as (
    select v,
      (case when public.is_following(auth.uid(), v.author_id) then 2 else 0 end)
      + (case when p_mood is not null and (v.mood::text = p_mood or v.hashtags && public.mood_tags(p_mood::public.video_mood)) then 3 else 0 end)
      + 1.5 * power(0.5, extract(epoch from (now() - v.created_at)) / 3600.0 / 48.0)
      + ln(1 + v.likes_count + 2 * v.comments_count + 3 * v.saves_count + 3 * v.shares_count) / 10.0
      + least((v.likes_count + 2 * v.comments_count + 3 * v.saves_count + 3 * v.shares_count)::numeric / greatest(v.views_count, 50), 1)
      - (case when exists (select 1 from public.video_views w where w.video_id = v.id and w.user_id = auth.uid()) then 4 else 0 end)
      - (case when v.author_id = auth.uid() then 1 else 0 end) as score
    from public.videos v
    where not (v.hashtags && coalesce(p_hidden_tags, '{}'))
      and (p_mood is null or v.mood::text = p_mood or v.hashtags && public.mood_tags(p_mood::public.video_mood))
      and v.created_at > now() - interval '60 days'
  ), diversified as (
    select v, score - 1.5 * (row_number() over (partition by (v).author_id order by score desc) - 1) as final_score
    from scored
  )
  select public.feed_row(v) from diversified order by final_score desc, (v).created_at desc limit least(p_limit, 100);
$$;

create or replace function public.feed_following(p_limit integer default 30)
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.videos v
  where v.author_id in (select followee_id from public.follows where follower_id = auth.uid())
  order by v.created_at desc limit least(p_limit, 100);
$$;

create or replace function public.videos_by_author(p_author uuid)
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.videos v where v.author_id = p_author order by v.created_at desc limit 200;
$$;

create or replace function public.my_saved_videos()
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.saves s join public.videos v on v.id = s.video_id
  where s.user_id = auth.uid() order by s.created_at desc limit 200;
$$;

create or replace function public.my_liked_videos()
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.likes l join public.videos v on v.id = l.video_id
  where l.user_id = auth.uid() order by l.created_at desc limit 200;
$$;

create or replace function public.videos_by_tag(p_tag text, p_sort text default 'popular')
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.videos v
  where lower(p_tag) = any (v.hashtags) and v.visibility = 'everyone'
  order by case when p_sort = 'newest' then extract(epoch from v.created_at) else v.views_count end desc
  limit 200;
$$;

create or replace function public.video_reactions(p_video uuid)
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.videos v where v.reply_to = p_video order by v.created_at desc limit 200;
$$;

create or replace function public.video_by_id(p_video uuid)
returns setof jsonb language sql stable set search_path = public as $$
  select public.feed_row(v) from public.videos v where v.id = p_video;
$$;

create or replace function public.search_videos(p_query text, p_sort text default 'relevance', p_mood text default null)
returns setof jsonb language sql stable set search_path = public as $$
  with q as (select lower(btrim(p_query, ' #@')) as t)
  select public.feed_row(v) from public.videos v, q
  where v.visibility = 'everyone' and length(q.t) > 0
    and (q.t = any (v.hashtags) or exists (select 1 from unnest(v.hashtags) h where h like q.t || '%')
         or v.caption ilike '%' || q.t || '%' or v.music_title ilike '%' || q.t || '%')
    and (p_mood is null or v.mood::text = p_mood or v.hashtags && public.mood_tags(p_mood::public.video_mood))
  order by
    case when p_sort = 'newest' then extract(epoch from v.created_at)
         when p_sort = 'popular' then v.views_count
         else (case when q.t = any (v.hashtags) then 1000000000 else 0 end) + v.likes_count end desc
  limit 60;
$$;

create or replace function public.search_profiles(p_query text)
returns setof public.profiles language sql stable set search_path = public as $$
  select p.* from public.profiles p
  where length(btrim(p_query, ' @')) > 0
    and (p.username ilike btrim(p_query, ' @') || '%' or p.display_name ilike '%' || btrim(p_query, ' @') || '%')
    and not public.is_blocked_between(auth.uid(), p.id)
  order by (p.username = lower(btrim(p_query, ' @'))) desc, p.followers_count desc
  limit 50;
$$;

create or replace function public.search_hashtags(p_query text)
returns table (tag text, video_count bigint, total_views bigint) language sql stable set search_path = public as $$
  select h as tag, count(*) as video_count, sum(v.views_count)::bigint as total_views
  from public.videos v, unnest(v.hashtags) h
  where v.visibility = 'everyone' and h like lower(btrim(p_query, ' #')) || '%'
  group by h order by count(*) desc, sum(v.views_count) desc limit 30;
$$;

create or replace function public.trending_hashtags(p_limit integer default 12)
returns table (tag text, video_count bigint, total_views bigint) language sql stable set search_path = public as $$
  select h as tag, count(*) as video_count, sum(v.views_count)::bigint as total_views
  from public.videos v, unnest(v.hashtags) h
  where v.visibility = 'everyone' and v.created_at > now() - interval '14 days'
  group by h order by sum(v.views_count) desc, count(*) desc limit least(p_limit, 50);
$$;

create or replace function public.challenge_leaderboard(p_challenge uuid, p_limit integer default 50)
returns table (rank bigint, score bigint, video jsonb) language sql stable set search_path = public as $$
  with c as (select * from public.challenges where id = p_challenge)
  select row_number() over (order by s.sc desc, s.created_at asc) as rank, s.sc as score, public.feed_row(s.v)
  from (
    select v, v.created_at, (v.likes_count + 2 * v.comments_count + 3 * v.shares_count + v.saves_count)::bigint as sc
    from public.videos v, c
    where v.visibility = 'everyone'
      and (v.challenge_tag = c.tag or c.tag = any (v.hashtags))
      and v.created_at >= c.starts_at and v.created_at < c.ends_at
  ) s
  order by rank limit least(p_limit, 100);
$$;

create or replace function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where username = lower(p_username) and id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'));
$$;

create or replace function public.my_blocked_profiles()
returns setof public.profiles language sql stable set search_path = public as $$
  select p.* from public.blocks b join public.profiles p on p.id = b.blocked_id where b.blocker_id = auth.uid();
$$;

create or replace function public.mark_notifications_read()
returns void language sql set search_path = public as $$
  update public.notifications set is_read = true where user_id = auth.uid() and not is_read;
$$;

-- Views/shares are counters only; they never expose who watched what to other users.
create or replace function public.record_view(p_video uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.videos v where v.id = p_video and public.can_view_video(v.author_id, v.visibility, v.is_hidden)) then
    return;
  end if;
  perform set_config('flexup.internal', 'on', true);
  update public.videos set views_count = views_count + 1 where id = p_video;
  perform set_config('flexup.internal', 'off', true);
  if auth.uid() is not null then
    insert into public.video_views (user_id, video_id) values (auth.uid(), p_video)
    on conflict (user_id, video_id) do update set viewed_at = now();
  end if;
end $$;

create or replace function public.record_share(p_video uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  perform set_config('flexup.internal', 'on', true);
  update public.videos set shares_count = shares_count + 1
   where id = p_video and public.can_view_video(author_id, visibility, is_hidden);
  perform set_config('flexup.internal', 'off', true);
end $$;

-- Account deletion (App Store guideline 5.1.1(v)). Cascades remove profile, videos, comments, likes…
-- Storage files are removed by the storage.objects delete below; on hosted Supabase prefer an Edge Function
-- calling the Storage API if you need guaranteed removal of the underlying S3 objects.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, storage as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  delete from storage.objects where bucket_id in ('videos', 'thumbnails', 'avatars') and (storage.foldername(name))[1] = uid::text;
  delete from auth.users where id = uid;
end $$;

revoke execute on function public.delete_my_account() from anon;

-- ---------------------------------------------------------------------
-- Storage: buckets + per-user folder policies
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('videos', 'videos', true, 104857600, array['video/mp4', 'video/quicktime']),
  ('thumbnails', 'thumbnails', true, 5242880, array['image/jpeg', 'image/png']),
  ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists "flexup upload own folder" on storage.objects;
create policy "flexup upload own folder" on storage.objects for insert to authenticated with check (
  bucket_id in ('videos', 'thumbnails', 'avatars') and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "flexup update own folder" on storage.objects;
create policy "flexup update own folder" on storage.objects for update to authenticated using (
  bucket_id in ('videos', 'thumbnails', 'avatars') and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "flexup delete own folder" on storage.objects;
create policy "flexup delete own folder" on storage.objects for delete to authenticated using (
  bucket_id in ('videos', 'thumbnails', 'avatars') and (storage.foldername(name))[1] = auth.uid()::text);

-- When a video row is deleted, drop its storage objects too.
create or replace function public.after_video_delete()
returns trigger language plpgsql security definer set search_path = public, storage as $$
begin
  delete from storage.objects
   where (bucket_id = 'videos' and name = old.storage_path)
      or (bucket_id = 'thumbnails' and name = split_part(old.storage_path, '.', 1) || '.jpg');
  return null;
end $$;

drop trigger if exists videos_storage_cleanup on public.videos;
create trigger videos_storage_cleanup after delete on public.videos for each row execute function public.after_video_delete();

-- ---------------------------------------------------------------------
-- FLEX CHALLENGE: daily rotation seed (run again or schedule with pg_cron)
-- ---------------------------------------------------------------------
create or replace function public.seed_daily_challenges(p_days integer default 30)
returns integer language plpgsql security definer set search_path = public as $$
declare
  templates jsonb := '[
    {"tag":"flexchallenge","title":"Утренний флекс","details":"Покажи, как ты заряжаешься с утра. 15 секунд энергии!","emoji":"⚡️"},
    {"tag":"тихийчас","title":"Тихий час","details":"Сними самое спокойное место рядом с тобой.","emoji":"🌊"},
    {"tag":"смешноедня","title":"Смешное дня","details":"Поймай нелепый момент, который случился сегодня.","emoji":"😂"},
    {"tag":"цветдня","title":"Цвет дня","details":"Ролик, где главный герой — один яркий цвет.","emoji":"🎨"},
    {"tag":"уютныйкадр","title":"Уютный кадр","details":"Тёплый свет, кофе, плед — покажи свой уют.","emoji":"☕️"},
    {"tag":"движение","title":"В движении","details":"Ни секунды без движения: бег, танец, велосипед.","emoji":"🏃"},
    {"tag":"доипосле","title":"До и после","details":"Трансформация за один ролик — комната, рисунок, образ.","emoji":"✨"}
  ]';
  d integer; t jsonb; day_start timestamptz; inserted integer := 0;
begin
  for d in 0..p_days - 1 loop
    day_start := date_trunc('day', now() at time zone 'utc') at time zone 'utc' + make_interval(days => d);
    t := templates -> ((extract(epoch from day_start)::bigint / 86400) % jsonb_array_length(templates))::integer;
    insert into public.challenges (tag, title, details, emoji, starts_at, ends_at)
    values (t ->> 'tag', t ->> 'title', t ->> 'details', t ->> 'emoji', day_start, day_start + interval '1 day')
    on conflict (tag, starts_at) do nothing;
    if found then inserted := inserted + 1; end if;
  end loop;
  return inserted;
end $$;

revoke execute on function public.seed_daily_challenges(integer) from anon, authenticated;
select public.seed_daily_challenges(30);

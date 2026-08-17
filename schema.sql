-- =====================================================================
--  BOARDGAME — Supabase 後端完整結構
--  https://0018him.github.io/boardgame/
--
--  呢個檔係後端嘅唯一事實來源。
--  改規則 = 改呢個檔 → commit → 貼相關段落入 Supabase SQL Editor Run。
--  由零重建 = 由頭到尾行一次呢個檔。
--
--  安全模型：
--    · 前端只有 anon key，anon key 係公開嘅（放喺 config.js）
--    · 所有寫入一律經 security definer function，冇任何 insert/update policy
--    · 題目正解、玩家角色、投票內容全部存喺冇 select policy 嘅表
--    · 玩家身分靠 player_secrets.token（uuid），唔用 Supabase Auth
-- =====================================================================


-- =====================================================================
--  1. 表
-- =====================================================================

-- 房間。public_state 存當前遊戲嘅「可公開」狀態（唔含答案）
create table if not exists rooms (
  code         text primary key,                              -- 6 位英數字房號
  game         text not null check (game in ('game1','game2')),
  filters      text[] not null default '{}',                  -- 選咗嘅題目分類
  host_id      uuid,
  phase        text not null default 'waiting',
  round        int  not null default 0,
  ends_at      timestamptz,                                   -- 當前階段死線
  public_state jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()             -- 靠佢觸發 realtime
);

create table if not exists players (
  id        uuid primary key default gen_random_uuid(),
  room_code text not null references rooms(code) on delete cascade,
  nickname  text not null,
  is_host   boolean not null default false,
  connected boolean not null default true,
  ready     boolean not null default false,
  score     int not null default 0,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);

create table if not exists chat_messages (
  id         bigserial primary key,
  room_code  text not null references rooms(code) on delete cascade,
  player_id  uuid,
  nickname   text not null,
  text       text not null,
  created_at timestamptz not null default now()
);

-- ---- 秘密表：以下三張永遠冇 select policy ----

-- 每房一行，存角色分配同正解
create table if not exists room_secrets (
  room_code       text primary key references rooms(code) on delete cascade,
  roles           jsonb  not null default '{}'::jsonb,  -- {player_id: judge|truth|bluffer}
  truth_id        uuid,
  judge_id        uuid,
  explanation     text,                                  -- game2 正解，只俾 truth 睇
  term            text,                                  -- game2 題目詞語（公開）
  used_ids        int[]  not null default '{}',          -- 已出過嘅題，避免重複
  votes           jsonb  not null default '{}'::jsonb,   -- game1 {player_id: 0|1}
  next_ready      jsonb  not null default '{}'::jsonb,   -- game1 準備下一題
  speak_order     uuid[] not null default '{}',          -- game2 發言名單（唔含諗樣）
  spoken          uuid[] not null default '{}',          -- game2 已發言
  current_speaker uuid,                                  -- game2 當前發言者
  speak_index     int not null default 0                 -- 保留欄位，現時未用
);

-- 玩家身分。token 就係前端嘅「密碼」，存喺 localStorage
create table if not exists player_secrets (
  player_id uuid primary key references players(id) on delete cascade,
  token     uuid not null default gen_random_uuid()
);

-- ---- 題庫：亦都冇 select policy，只可經 function 讀 ----

-- game1 心有靈犀一點通
create table if not exists questions_g1 (
  id       int primary key,
  category text not null,
  type     text not null default 'binary',
  question text not null,
  options  text[] not null                                -- 一定係兩個
);

-- game2 9upper 瞎掰王
create table if not exists questions_g2 (
  id          int primary key,
  category    text not null,
  term        text not null,                              -- 公開俾大家 9up
  explanation text                                        -- 只有老實人睇到
);

create index if not exists players_room_idx  on players (room_code);
create index if not exists chat_room_idx     on chat_messages (room_code, created_at);
create index if not exists q1_cat_idx        on questions_g1 (category);
create index if not exists q2_cat_idx        on questions_g2 (category);


-- =====================================================================
--  2. RLS
--     只開 select，而且只開俾非秘密嘅三張表。
--     完全冇 insert / update / delete policy —— 寫入一律經 function。
-- =====================================================================

alter table rooms          enable row level security;
alter table players        enable row level security;
alter table chat_messages  enable row level security;
alter table room_secrets   enable row level security;
alter table player_secrets enable row level security;
alter table questions_g1   enable row level security;
alter table questions_g2   enable row level security;

drop policy if exists "read rooms"   on rooms;
drop policy if exists "read players" on players;
drop policy if exists "read chat"    on chat_messages;

create policy "read rooms"   on rooms         for select using (true);
create policy "read players" on players       for select using (true);
create policy "read chat"    on chat_messages for select using (true);


-- =====================================================================
--  3. Realtime
--     前端收到通知後會再叫 get_state 攞完整狀態，
--     所以只需要 publish 呢三張表做「有嘢變咗」嘅訊號。
-- =====================================================================

alter publication supabase_realtime add table rooms;
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table chat_messages;

alter table rooms         replica identity full;
alter table players       replica identity full;
alter table chat_messages replica identity full;


-- =====================================================================
--  4. 內部 helper（前綴 _ ＝ 唔應該由前端直接叫）
-- =====================================================================

create or replace function _gen_code() returns text
language plpgsql security definer set search_path=public as $$
declare c text;
begin
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from rooms where code = c);
  end loop;
  return c;
end $$;

-- 撩一撩 updated_at，令 realtime 發出通知
create or replace function _bump(p_code text) returns void
language sql security definer set search_path=public as $$
  update rooms set updated_at = now() where code = p_code;
$$;

create or replace function _pid(p_token uuid) returns uuid
language sql security definer set search_path=public stable as $$
  select player_id from player_secrets where token = p_token;
$$;


-- =====================================================================
--  5. 房間生命週期
-- =====================================================================

-- 開房。p_filters 唔啱或者空就自動用晒全部分類。
create or replace function create_room(p_game text, p_filters text[])
returns text
language plpgsql security definer set search_path=public as $$
declare v_code text; v_allowed text[]; v_use text[];
begin
  if p_game not in ('game1','game2') then
    raise exception '遊戲類型錯誤。';
  end if;

  if p_game = 'game1' then
    select array_agg(distinct category) into v_allowed from questions_g1;
  else
    select array_agg(distinct category) into v_allowed from questions_g2;
  end if;

  v_use := array(
    select unnest(coalesce(p_filters,'{}'))
    intersect select unnest(coalesce(v_allowed,'{}'))
  );
  if coalesce(array_length(v_use,1),0) = 0 then
    v_use := coalesce(v_allowed,'{}');
  end if;

  v_code := _gen_code();
  insert into rooms(code, game, filters) values (v_code, p_game, v_use);
  insert into room_secrets(room_code) values (v_code);
  return v_code;
end $$;

-- 入房。第一個入嘅自動做房主。回傳 {playerId, token, code}
create or replace function join_room(p_code text, p_nickname text)
returns json
language plpgsql security definer set search_path=public as $$
declare r rooms; n int; v_id uuid; v_token uuid; v_name text;
begin
  select * into r from rooms where code = upper(p_code) for update;
  if not found then raise exception '房間唔存在。'; end if;
  if r.phase <> 'waiting' then raise exception '遊戲已經開始咗。'; end if;

  select count(*) into n from players where room_code = r.code;
  if n >= 6 then raise exception '房間已滿。'; end if;

  v_name := nullif(btrim(coalesce(p_nickname,'')),'');
  v_name := left(coalesce(v_name,'玩家'), 12);

  insert into players(room_code, nickname, is_host)
  values (r.code, v_name, n = 0)
  returning id into v_id;

  insert into player_secrets(player_id) values (v_id)
  returning token into v_token;

  if n = 0 then
    update rooms set host_id = v_id where code = r.code;
  end if;

  perform _bump(r.code);
  return json_build_object('playerId', v_id, 'token', v_token, 'code', r.code);
end $$;

-- 心跳 / 重連
create or replace function touch_player(p_token uuid)
returns json
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; v_was boolean;
begin
  select ps.player_id, p.room_code, p.connected
    into v_id, v_code, v_was
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效，請重新入房。'; end if;

  update players set last_seen = now(), connected = true where id = v_id;
  if not v_was then perform _bump(v_code); end if;
  return json_build_object('playerId', v_id, 'code', v_code);
end $$;

-- 離開。房主離開會自動轉俾下一個仲在線嘅人。
create or replace function leave_room(p_token uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; v_next uuid;
begin
  select ps.player_id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then return; end if;

  update players set connected = false, last_seen = now() where id = v_id;

  if exists (select 1 from rooms where code = v_code and host_id = v_id) then
    select id into v_next from players
     where room_code = v_code and connected and id <> v_id
     order by joined_at limit 1;
    if v_next is not null then
      update players set is_host = false where room_code = v_code;
      update players set is_host = true  where id = v_next;
      update rooms  set host_id = v_next where code = v_code;
    end if;
  end if;

  perform _bump(v_code);
end $$;

create or replace function set_ready(p_token uuid, p_ready boolean) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text;
begin
  select ps.player_id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  update players set ready = coalesce(p_ready, true) where id = v_id;
  perform _bump(v_code);
end $$;

-- 攞分類清單（前端畫 checkbox 用，永遠同題庫同步）
create or replace function list_categories(p_game text)
returns text[]
language sql security definer set search_path=public stable as $$
  select coalesce(array_agg(distinct category order by category), '{}')
    from (
      select category from questions_g1 where p_game = 'game1'
      union all
      select category from questions_g2 where p_game = 'game2'
    ) t;
$$;


-- =====================================================================
--  6. GAME 1 — 心有靈犀一點通
--
--  流程：  vote (10s) ──► chat ──► 房主撳下一題 ──► vote …
--  計分：  暫時唔計分，純粹睇邊個選項多人揀
-- =====================================================================

-- 由 room_secrets.votes 重算公開票數。
-- 重點：vote 階段唔會公開邊個投咗咩，只出總數。
create or replace function _g1_sync(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_secrets;
        c0 int; c1 int; vt0 jsonb; vt1 jsonb; nr int;
begin
  select * into r from rooms         where code = p_code;
  select * into s from room_secrets  where room_code = p_code;

  select count(*) filter (where sv.value::int = 0),
         count(*) filter (where sv.value::int = 1)
    into c0, c1
    from jsonb_each_text(s.votes) sv;

  select coalesce(jsonb_agg(p.nickname) filter (where sv.value::int = 0), '[]'::jsonb),
         coalesce(jsonb_agg(p.nickname) filter (where sv.value::int = 1), '[]'::jsonb)
    into vt0, vt1
    from jsonb_each_text(s.votes) sv
    join players p on p.id = sv.key::uuid;

  select count(*) into nr from jsonb_object_keys(s.next_ready);

  update rooms set public_state = jsonb_build_object(
    'question',        coalesce(public_state -> 'question', 'null'::jsonb),
    'votes',           jsonb_build_object('0', c0, '1', c1),
    'voteCounts',      jsonb_build_array(c0, c1),
    'voters',          case when r.phase = 'vote'
                            then jsonb_build_object('0','[]'::jsonb,'1','[]'::jsonb)
                            else jsonb_build_object('0', vt0, '1', vt1) end,
    'submittedCount',  c0 + c1,
    'nextReadyCount',  nr,
    'winner',          case when r.phase = 'vote' or c0 = c1 then null
                            when c0 > c1 then 0 else 1 end
  ) where code = p_code;
end $$;

-- 抽新題目、洗走上一題嘅票
create or replace function _g1_start(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_secrets; q questions_g1;
begin
  select * into r from rooms        where code = p_code;
  select * into s from room_secrets where room_code = p_code;

  select * into q from questions_g1
   where category = any(r.filters) and not (id = any(s.used_ids))
   order by random() limit 1;

  -- 全部出完就重新洗牌
  if not found then
    update room_secrets set used_ids = '{}' where room_code = p_code;
    select * into q from questions_g1
     where category = any(r.filters) order by random() limit 1;
  end if;

  if not found then raise exception '題庫冇符合條件嘅題目。'; end if;

  update room_secrets
     set votes = '{}'::jsonb, next_ready = '{}'::jsonb,
         used_ids = array_append(used_ids, q.id)
   where room_code = p_code;

  update rooms
     set phase = 'vote', round = round + 1,
         ends_at = now() + interval '10 seconds',
         public_state = jsonb_build_object('question', jsonb_build_object(
           'id', q.id, 'category', q.category,
           'question', q.question, 'options', to_jsonb(q.options)))
   where code = p_code;

  perform _g1_sync(p_code);
  perform _bump(p_code);
end $$;

-- 封票，公開結果
create or replace function _g1_lock(p_code text) returns void
language plpgsql security definer set search_path=public as $$
begin
  update rooms set phase = 'chat', ends_at = null
   where code = p_code and phase = 'vote';
  if not found then return; end if;
  perform _g1_sync(p_code);
  perform _bump(p_code);
end $$;

-- 投票。全部在線玩家投晒會即刻封票，唔使等夠 10 秒。
create or replace function g1_vote(p_token uuid, p_option int) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; r rooms; n int; voted int;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token and p.connected;
  if v_id is null then raise exception '連線失效。'; end if;

  select * into r from rooms where code = v_code for update;
  if r.phase <> 'vote' then return; end if;
  if p_option is null or p_option not in (0, 1) then return; end if;
  if exists (select 1 from room_secrets
              where room_code = v_code and votes ? v_id::text) then return; end if;

  update room_secrets set votes = votes || jsonb_build_object(v_id::text, p_option)
   where room_code = v_code;
  perform _g1_sync(v_code);

  select count(*) into n from players where room_code = v_code and connected;
  select count(*) into voted
    from jsonb_object_keys((select votes from room_secrets where room_code = v_code));

  if n >= 2 and voted >= n then perform _g1_lock(v_code);
  else perform _bump(v_code); end if;
end $$;

-- 非房主撳「準備好」，純粹俾房主睇個計數
create or replace function g1_ready(p_token uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; ph text;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token and p.connected;
  if v_id is null then raise exception '連線失效。'; end if;

  select phase into ph from rooms where code = v_code;
  if ph <> 'chat' then return; end if;

  update room_secrets set next_ready = next_ready || jsonb_build_object(v_id::text, true)
   where room_code = v_code;
  perform _g1_sync(v_code);
  perform _bump(v_code);
end $$;

create or replace function g1_next(p_token uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; r rooms;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  select * into r from rooms where code = v_code for update;
  if r.phase <> 'chat' then return; end if;
  if r.host_id <> v_id then raise exception '只有房主先可以入下一題。'; end if;

  perform _g1_start(v_code);
end $$;


-- =====================================================================
--  7. GAME 2 — 9upper 瞎掰王
--
--  角色：judge（諗樣）／truth（老實人）／bluffer（9upper）
--
--  流程：
--    prep     30s   全部人睇詞語，只有老實人收到正解
--    picking  10s   諗樣揀下一個發言者；逾時隨機
--    speaking 30s   只有當前發言者可以打字
--    （picking / speaking 交替，直到所有人講完）
--    judge   120s   諗樣揀邊個係老實人；逾時隨機
--    result         公開正解同身分，房主可以開下一局
--
--  計分：估中 → 諗樣 +2、老實人 +2
--        估錯 → 全部 9upper 各 +1
-- =====================================================================

-- 重建 public_state。呢個 function 決定咗「邊啲嘢外人睇得到」。
create or replace function _g2_public(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_secrets; js jsonb;
begin
  select * into r from rooms        where code = p_code;
  select * into s from room_secrets where room_code = p_code;

  js := jsonb_build_object(
    'term',            s.term,
    'judgeId',         s.judge_id,
    'order',           to_jsonb(s.speak_order),
    'spokenIds',       to_jsonb(s.spoken),
    'currentPlayerId', case when r.phase = 'speaking'
                            then to_jsonb(s.current_speaker) else 'null'::jsonb end
  );

  -- 諗樣揀下一位發言者：只列仲未講過嘅人
  if r.phase = 'picking' then
    js := js || jsonb_build_object('candidates', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nickname', p.nickname)
             order by p.joined_at)
        from players p
       where p.room_code = p_code
         and p.id = any(s.speak_order)
         and not (p.id = any(s.spoken))), '[]'::jsonb));
  end if;

  -- 諗樣指認：除咗自己以外全部人
  if r.phase = 'judge' then
    js := js || jsonb_build_object('choices', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nickname', p.nickname)
             order by p.joined_at)
        from players p
       where p.room_code = p_code and p.id <> s.judge_id), '[]'::jsonb));
  end if;

  -- 淨係喺 result 階段先公開正解同老實人身分
  if r.phase = 'result' then
    js := js
      || (r.public_state - 'choices' - 'candidates')
      || jsonb_build_object(
           'truthId',            s.truth_id,
           'truthNickname',      (select nickname from players where id = s.truth_id),
           'correctExplanation', coalesce(s.explanation, ''),
           'scores',             coalesce((select jsonb_object_agg(p.id::text, p.score)
                                             from players p where p.room_code = p_code),
                                          '{}'::jsonb));
  end if;

  update rooms set public_state = js where code = p_code;
end $$;

-- 開新一局：抽題、分角色、排發言次序（唔包諗樣）
create or replace function _g2_start(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_secrets; q questions_g2;
        v_ids uuid[]; v_judge uuid; v_truth uuid; v_roles jsonb;
begin
  select * into r from rooms        where code = p_code;
  select * into s from room_secrets where room_code = p_code;

  select array_agg(id order by random()) into v_ids
    from players where room_code = p_code and connected;
  if coalesce(array_length(v_ids,1),0) < 4 then
    raise exception '需要 4 位玩家。';
  end if;

  v_judge := v_ids[1];
  v_truth := v_ids[2];

  select * into q from questions_g2
   where category = any(r.filters) and not (id = any(s.used_ids))
   order by random() limit 1;
  if not found then
    update room_secrets set used_ids = '{}' where room_code = p_code;
    select * into q from questions_g2
     where category = any(r.filters) order by random() limit 1;
  end if;
  if not found then raise exception '題庫冇符合條件嘅題目。'; end if;

  select jsonb_object_agg(id::text,
           case when id = v_judge then 'judge'
                when id = v_truth then 'truth'
                else 'bluffer' end)
    into v_roles from unnest(v_ids) as id;

  update room_secrets
     set roles = v_roles, judge_id = v_judge, truth_id = v_truth,
         explanation = q.explanation, term = q.term,
         used_ids = array_append(used_ids, q.id),
         speak_order = (select array_agg(x) from unnest(v_ids) x where x <> v_judge),
         spoken = '{}', current_speaker = null, speak_index = 0
   where room_code = p_code;

  update rooms
     set phase = 'prep', round = round + 1,
         ends_at = now() + interval '30 seconds'
   where code = p_code;

  perform _g2_public(p_code);
  perform _bump(p_code);
end $$;

-- 轉入「揀發言者」；冇人剩就入指認階段
create or replace function _g2_to_picking(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare s room_secrets; n int;
begin
  select * into s from room_secrets where room_code = p_code;

  select count(*) into n
    from unnest(s.speak_order) x where not (x = any(s.spoken));

  if n = 0 then
    update rooms set phase = 'judge', ends_at = now() + interval '120 seconds'
     where code = p_code;
  else
    update rooms set phase = 'picking', ends_at = now() + interval '10 seconds'
     where code = p_code;
  end if;

  perform _g2_public(p_code);
  perform _bump(p_code);
end $$;

create or replace function _g2_set_speaker(p_code text, p_target uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  update room_secrets set current_speaker = p_target where room_code = p_code;
  update rooms set phase = 'speaking', ends_at = now() + interval '30 seconds'
   where code = p_code;
  perform _g2_public(p_code);
  perform _bump(p_code);
end $$;

-- 諗樣點選下一位
create or replace function g2_pick(p_token uuid, p_target uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; s room_secrets;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  perform 1 from rooms where code = v_code and phase = 'picking' for update;
  if not found then return; end if;

  select * into s from room_secrets where room_code = v_code;
  if s.judge_id <> v_id then return; end if;
  if not (p_target = any(s.speak_order)) or p_target = any(s.spoken) then return; end if;

  perform _g2_set_speaker(v_code, p_target);
end $$;

-- 10 秒逾時：隨機揀一個未講過嘅
create or replace function _g2_auto_pick(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare s room_secrets; v_target uuid;
begin
  select * into s from room_secrets where room_code = p_code;
  select x into v_target from unnest(s.speak_order) x
   where not (x = any(s.spoken)) order by random() limit 1;

  if v_target is null then perform _g2_to_picking(p_code); return; end if;
  perform _g2_set_speaker(p_code, v_target);
end $$;

create or replace function _g2_end_speak(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare s room_secrets;
begin
  select * into s from room_secrets where room_code = p_code;
  if s.current_speaker is not null then
    update room_secrets
       set spoken = array_append(spoken, s.current_speaker),
           current_speaker = null
     where room_code = p_code;
  end if;
  perform _g2_to_picking(p_code);
end $$;

-- 結算。手動指認同逾時隨機指認都行呢個。
create or replace function _g2_resolve(p_code text, p_target uuid) returns void
language plpgsql security definer set search_path=public as $$
declare s room_secrets; v_ok boolean;
begin
  select * into s from room_secrets where room_code = p_code;
  v_ok := (p_target = s.truth_id);

  if v_ok then
    update players set score = score + 2
     where room_code = p_code and id in (s.judge_id, s.truth_id);
  else
    update players set score = score + 1
     where room_code = p_code and id not in (s.judge_id, s.truth_id);
  end if;

  update rooms
     set phase = 'result', ends_at = null,
         public_state = public_state || jsonb_build_object(
           'targetId', p_target, 'correct', v_ok)
   where code = p_code;

  perform _g2_public(p_code);
  perform _bump(p_code);
end $$;

create or replace function g2_judge(p_token uuid, p_target uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; s room_secrets;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  perform 1 from rooms where code = v_code and phase = 'judge' for update;
  if not found then return; end if;

  select * into s from room_secrets where room_code = v_code;
  if s.judge_id <> v_id then return; end if;
  if not exists (select 1 from players
                  where id = p_target and room_code = v_code and id <> s.judge_id) then
    return;
  end if;

  perform _g2_resolve(v_code, p_target);
end $$;

create or replace function g2_next(p_token uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; r rooms;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  select * into r from rooms where code = v_code for update;
  if r.phase <> 'result' then return; end if;
  if r.host_id <> v_id then raise exception '只有房主先可以開下一局。'; end if;

  perform _g2_start(v_code);
end $$;


-- =====================================================================
--  8. 共用動作
-- =====================================================================

-- 開始遊戲。心有靈犀要 2 人，9upper 要 4 人。
create or replace function start_game(p_token uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; r rooms; n int; need int;
begin
  select p.id, p.room_code into v_id, v_code
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token;
  if v_id is null then raise exception '連線失效。'; end if;

  select * into r from rooms where code = v_code for update;
  if r.host_id <> v_id then raise exception '只有房主先可以開始遊戲。'; end if;
  if r.phase <> 'waiting' then raise exception '遊戲已經開始咗。'; end if;

  need := case when r.game = 'game1' then 2 else 4 end;
  select count(*) into n from players where room_code = v_code and connected;
  if n < need then
    raise exception '需要 % 位玩家先可以開始。', need;
  end if;

  if r.game = 'game1' then perform _g1_start(v_code);
  else perform _g2_start(v_code); end if;
end $$;

-- 發言。speaking 階段只准當前發言者出聲。
create or replace function send_chat(p_token uuid, p_text text) returns void
language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_code text; v_name text; r rooms; s room_secrets; clean text;
begin
  select p.id, p.room_code, p.nickname into v_id, v_code, v_name
    from player_secrets ps join players p on p.id = ps.player_id
   where ps.token = p_token and p.connected;
  if v_id is null then raise exception '連線失效。'; end if;

  clean := left(btrim(coalesce(p_text, '')), 400);
  if clean = '' then return; end if;

  select * into r from rooms where code = v_code;
  if r.phase not in ('chat', 'speaking') then return; end if;

  if r.phase = 'speaking' then
    select * into s from room_secrets where room_code = v_code;
    if s.current_speaker is distinct from v_id then return; end if;
  end if;

  insert into chat_messages(room_code, player_id, nickname, text)
  values (v_code, v_id, v_name, clean);
end $$;


-- =====================================================================
--  9. 計時
--
--  Supabase 冇 per-room 伺服器計時器（唔似 Cloudflare Durable Object
--  嘅 alarm()），所以時間由客戶端推進：任何人叫 get_state 都會順手
--  行一次 tick。
--
--  安全性由 tick 自己保證：`ends_at > now() 就即刻 return`，加上
--  `for update` 行鎖，所以五個人同時叫都只有一次會真正推進。
-- =====================================================================

create or replace function tick(p_code text) returns void
language plpgsql security definer set search_path=public as $$
declare r rooms; s room_secrets; v_target uuid;
begin
  select * into r from rooms where code = upper(p_code) for update;
  if not found or r.ends_at is null or r.ends_at > now() then return; end if;

  if r.game = 'game1' and r.phase = 'vote' then
    perform _g1_lock(r.code);

  elsif r.game = 'game2' then
    if r.phase = 'prep' then
      perform _g2_to_picking(r.code);

    elsif r.phase = 'picking' then
      perform _g2_auto_pick(r.code);

    elsif r.phase = 'speaking' then
      perform _g2_end_speak(r.code);

    elsif r.phase = 'judge' then
      -- 諗樣 2 分鐘唔揀 → 隨機指認，照正常規則結算
      select * into s from room_secrets where room_code = r.code;
      select id into v_target from players
       where room_code = r.code and id <> s.judge_id order by random() limit 1;
      if v_target is not null then perform _g2_resolve(r.code, v_target); end if;
    end if;
  end if;
end $$;


-- =====================================================================
--  10. get_state — 前端唯一嘅狀態出口
--
--  ⚠️ 呢個 function 係整套保密機制嘅樽頸。改佢之前諗清楚：
--     · viewerExplanation 只有 role = 'truth' 先攞到
--     · gameState 入面嘅嘢係「全場都睇得到」，唔可以放答案
--     · correctExplanation 只喺 result 階段先由 _g2_public 加入去
--
--  ⚠️ 唔可以標 stable / immutable —— 佢會 tick，即係會寫入。
-- =====================================================================

create or replace function get_state(p_code text, p_token uuid default null)
returns json
language plpgsql security definer set search_path=public as $$
declare r rooms; v_pid uuid; v_role text; v_expl text;
        v_gs jsonb; v_players json;
begin
  perform tick(p_code);

  select * into r from rooms where code = upper(p_code);
  if not found then raise exception '房間唔存在。'; end if;

  if p_token is not null then
    select p.id into v_pid
      from player_secrets ps join players p on p.id = ps.player_id
     where ps.token = p_token and p.room_code = r.code;
  end if;

  select json_agg(json_build_object(
           'id', p.id, 'nickname', p.nickname,
           'host', p.id = r.host_id, 'connected', p.connected,
           'ready', p.ready, 'score', p.score
         ) order by p.joined_at)
    into v_players
    from players p where p.room_code = r.code;

  v_gs := coalesce(r.public_state, '{}'::jsonb) || jsonb_build_object(
    'phase',  r.phase,
    'round',  r.round,
    'endsAt', case when r.ends_at is null then null
                   else (extract(epoch from r.ends_at) * 1000)::bigint end
  );

  if v_pid is not null then
    select rs.roles ->> v_pid::text, rs.explanation into v_role, v_expl
      from room_secrets rs where rs.room_code = r.code;

    -- 唔係老實人就一定攞唔到正解
    if v_role is distinct from 'truth' then v_expl := null; end if;

    if r.phase = 'vote' then
      v_gs := v_gs || jsonb_build_object('myVote',
        (select rs.votes -> v_pid::text from room_secrets rs
          where rs.room_code = r.code));
    end if;
  end if;

  return json_build_object(
    'code',              r.code,
    'game',              r.game,
    'filters',           r.filters,
    'hostId',            r.host_id,
    'players',           coalesce(v_players, '[]'::json),
    'gameState',         case when r.phase = 'waiting' then null else v_gs end,
    'viewerRole',        v_role,
    'viewerExplanation', v_expl
  );
end $$;

-- 前端主要用呢個：推進時間 + 攞狀態，一次 round trip 搞掂
create or replace function sync(p_code text, p_token uuid default null)
returns json
language plpgsql security definer set search_path=public as $$
begin
  perform tick(p_code);
  return get_state(p_code, p_token);
end $$;


-- =====================================================================
--  11. 清理（可選，手動行）
-- =====================================================================

-- 清走兩個鐘冇郁過嘅房間（players / chat / secrets 會 cascade 一齊刪）
-- delete from rooms where updated_at < now() - interval '2 hours';


-- =====================================================================
--  12. 前端呼叫對照表
--
--  app.js 嘅 send({type: ...}) → RPC
--
--    ready       → set_ready(token, ready)
--    start       → start_game(token)
--    g1:vote     → g1_vote(token, option)
--    g1:chat     → send_chat(token, text)
--    g1:next     → 房主 g1_next(token) ／ 其他人 g1_ready(token)
--    g2:chat     → send_chat(token, text)
--    g2:pick     → g2_pick(token, targetId)
--    g2:judge    → g2_judge(token, targetId)
--    g2:next     → g2_next(token)
--
--  其他：
--    開房        → create_room(game, filters[])
--    入房        → join_room(code, nickname)
--    重連 / 心跳 → touch_player(token)
--    離開        → leave_room(token)
--    分類清單    → list_categories(game)
--    刷新        → sync(code, token)
--
--  題庫要改內容，直接喺 Table Editor 改 questions_g1 / questions_g2，
--  唔使改 code，亦唔使重新部署。
-- =====================================================================

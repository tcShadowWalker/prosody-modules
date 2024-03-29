-- mod_storage_gdbm
-- Copyright (C) 2014-2015 Kim Alvefur
--
-- This file is MIT/X11 licensed.
-- 
-- Depends on lgdbm:
-- http://webserver2.tecgraf.puc-rio.br/~lhf/ftp/lua/#lgdbm

local gdbm = require"gdbm";
local path = require"util.paths";
local lfs = require"lfs";
local st = require"util.stanza";
local uuid = require"util.uuid".generate;

local serialization = require"util.serialization";
local serialize = serialization.serialize;
local deserialize = serialization.deserialize;

local g_set, g_get, g_del = gdbm.replace, gdbm.fetch, gdbm.delete;
local g_first, g_next = gdbm.firstkey, gdbm.nextkey;

local t_remove = table.remove;

local empty = {};

local function id(v) return v; end

local function is_stanza(s)
	return getmetatable(s) == st.stanza_mt;
end

local function t(c, a, b)
	if c then return a; end return b;
end

local base_path = path.resolve_relative_path(prosody.paths.data, module.host);
lfs.mkdir(base_path);

local cache = {};

local keyval = {};
local keyval_mt = { __index = keyval, suffix = ".db" };

function keyval:set(user, value)
	if type(value) == "table" and next(value) == nil then
		value = nil;
	end
	if value ~= nil then
		value = serialize(value);
	end
	local ok, err = (value and g_set or g_del)(self._db, user or "@", value);
	if not ok then return nil, err; end
	return true;
end

function keyval:get(user)
	local data, err = g_get(self._db, user or "@");
	if not data then return nil, err; end
	return deserialize(data);
end

local function g_keys(db, key)
	return (key == nil and g_first or g_next)(db, key);
end

function keyval:users()
	return g_keys, self._db, nil;
end

local archive = {};
local archive_mt = { __index = archive, suffix = ".adb" };

archive.get = keyval.get;
archive.set = keyval.set;

function archive:append(username, key, when, with, value)
	key = key or uuid();
	local meta = self:get(username);
	if not meta then
		meta = {};
	end
	local i = meta[key] or #meta+1;
	local type;
	if is_stanza(value) then
		type, value = "stanza", st.preserialize(value);
	end
	meta[i] = { key = key, when = when, with = with, type = type };
	meta[key] = i;
	local prefix = (username or "@") .. "#";
	local ok, err = self:set(prefix..key, value);
	if not ok then return nil, err; end
	ok, err = self:set(username, meta);
	if not ok then return nil, err; end
	return key;
end

local deserialize = {
	stanza = st.deserialize;
};

function archive:find(username, query)
	query = query or empty;
	local meta = self:get(username) or empty;
	local prefix = (username or "@") .. "#";
	local r = query.reverse;
	local d = t(r, -1, 1);
	local s = meta[t(r, query.before, query.after)];
	local limit = query.limit;
	if s then
		s = s + d;
	else
		s = t(r, #meta, 1)
	end
	local e = t(r, 1, #meta);
	local c = 0;
	return function ()
		if limit and c >= limit then return end
		local item, value;
		for i = s, e, d do
			item = meta[i];
			if (not query.with or item.with == query.with)
			and (not query.start or item.when >= query.start)
			and (not query["end"] or item.when <= query["end"]) then
				s = i + d; c = c + 1;
				value = self:get(prefix..item.key);
				return item.key, (deserialize[item.type] or id)(value), item.when, item.with;
			end
		end
	end
end

local drivers = {
	keyval = keyval_mt;
	archive = archive_mt;
}

function open(_, store, typ)
	typ = typ or "keyval";
	local driver_mt = drivers[typ];
	if not driver_mt then
		return nil, "unsupported-store";
	end

	local db_path = path.join(base_path, store) .. driver_mt.suffix;

	local db = cache[db_path];
	if not db then
		db = assert(gdbm.open(db_path, "c"));
		cache[db_path] = db;
	end
	return setmetatable({ _db = db; _path = db_path; store = store, typ = type }, driver_mt);
end

function purge(_, user)
	for dir in lfs.dir(base_path) do
		local name, ext = dir:match("^(.-)%.a?db$");
		if ext == ".db" then
			open(_, name, "keyval"):set(user, nil);
		elseif ext == ".adb" then
			open(_, name, "archive"):delete(user);
		end
	end
	return true;
end

function module.unload()
	for path, db in pairs(cache) do
		gdbm.sync(db);
		gdbm.close(db);
	end
end

module:provides"storage";

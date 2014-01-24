#!/usr/bin/lua5.2

local abuild = require("aports.abuild")
local apkrepo = require("aports.apkrepo")
local lfs = require("lfs")

local function warn(formatstr, ...)
	io.stderr:write(("WARNING: %s\n"):format(formatstr:format(...)))
end

local function err(formatstr, ...)
	io.stderr:write(("ERROR: %s\n"):format(formatstr:format(...)))
end

local function fatal(exitcode, formatstr, ...)
	err(formatstr, ...)
	os.exit(exitcode)
end

local function parse_opts(opthelp, raw_args)
	local valid_opts = {}
	local opts = {}
	local args = {}
	local moreopts = true
	for optc, separator in opthelp:gmatch("%s+%-(%a)(%s+)") do
		valid_opts[optc] = { hasarg = (separator == " ") }
	end

	local i = 1
	while i <= #raw_args do
		local a = raw_args[i]
		i = i + 1
		if a == "--" then
			moreopts = false
		elseif moreopts and a:sub(1,1) == "-" then
			for j = 2, #a do
				local opt = a:sub(j,j)
				if not valid_opts[opt] then
					return nil, opt, "invalid option"
				end
				if valid_opts[opt].hasarg then
					opts[opt] = raw_args[i]
					i = i + 1
				else
					opts[opt] = true
				end
				if not opts[opt] then
					return nil, opt, "optarg required"
				end
			end
		else
			args[#args + 1] = a
		end
	end
	return opts, args
end

local function skip_aport(aport)
	local dirattr = lfs.attributes(aport.dir.."/src/")
	local fileattr = lfs.attributes(aport.dir.."/APKBUILD")
	if not dirattr or not fileattr then
		return false
	end
	if os.difftime(fileattr.modification, dirattr.modification) > 0 then
		return false
	end
	warn("%s: Skipped due to previous build failure", aport.pkgname)
	return true
end

local function build_aport(aport, repodest, logdir, skip_failed)
	local success, errmsg = lfs.chdir(aport.dir)
	if not success then
		err("%s", errmsg)
		return nil
	end
	if skip_failed and skip_aport(aport) then
		return nil
	end
	local logredirect = ""
	if logdir ~= nil then
		local dir = ("%s/%s"):format(logdir, aport.pkgname)
		if not lfs.attributes(dir) then
			assert(lfs.mkdir(dir), dir)
		end
		local logfile = ("%s/%s-%s-r%s.log"):format(dir, aport.pkgname, aport.pkgver, aport.pkgrel)

		logredirect = ("> '%s' 2>&1"):format(logfile)
	end
	local cmd = ("REPODEST='%s' abuild -r -m %s"):format(repodest, logredirect)
	success = os.execute(cmd)
	if not success then
		err("%s: Failed to build", aport.pkgname)
	end
	return success
end

-----------------------------------------------------------------
local opthelp = [[
 -a DIR     Set the aports base dir to DIR instead of $HOME/aports
 -d DIR     Set destination repository base to DIR instead of $HOME/packages
 -h	    Show this help and exit
 -l DIR     Create build logs in DIR/REPO/pkgname/ instead of stdout
 -k         Keep going, even if packages fails
 -n         Dry run. Don't acutally build or delete, just print
 -p         Purge obsolete packages from REPODIR after build
 -r REPO    Dependencies are found in REPO
 -s         Skip those who previously failed (src dir exists)
]]

local function usage(exitcode)
	io.stdout:write(("options:\n%s\n"):format(opthelp))
	os.exit(exitcode)
end

opts, args, errmsg = parse_opts(opthelp, arg)
if opts == nil then
	io.stderr:write(("%s: -%s\n"):format(errmsg, args))
	usage(1)
end

if opts.h then
	usage(0)
end

if #args == 0 then
	usage(1)
end

homedir = os.getenv("HOME")
aportsdir = opts.a or ("%s/aports"):format(homedir)
repodest = opts.d or abuild.repodest or ("%s/packages"):format(homedir)
logdirbase = opts.l

if opts.n then
	build_aport = function() return true end
end

stats = {}
for _,repo in pairs(args) do
	local db = require('aports.db').new(aportsdir, repo)
	local pkgs = {}
	local unsorted = {}
	local logdir = nil
	stats[repo] = {}
	local start_time = os.clock()

	-- count total aports
	stats[repo].aports = 0
	for aport in db:each_aport() do
		if aport:arch_enabled() then
			stats[repo].aports = stats[repo].aports + 1
		end
	end

	-- find out what needs to be built
	for aport in db:each_need_build() do
		table.insert(pkgs, aport.pkgname)
		if unsorted[aport.pkgname] then
			warn("more than one aport provides %s", aport.pkgname)
		end
		unsorted[aport.pkgname] = true
	end

	if logdirbase ~= nil then
		logdir = ("%s/%s"):format(logdirbase, repo)
		if not lfs.attributes(logdir) then
			assert(lfs.mkdir(logdir), logdir)
		end
	end

	-- build packages
	local built = 0
	local tried = 0
	for aport in db:each_in_build_order(pkgs) do
		tried = tried + 1
		local totally_built = stats[repo].aports - #pkgs + built
		io.write(("%d/%d %d/%d %s\n"):format(tried, #pkgs,
					totally_built, stats[repo].aports,
					aport.pkgname))
		if not db:known_deps_exists(aport) then
			warn("%s: Skipped due to missing dependencies", aport.pkgname)
		elseif build_aport(aport, repodest, logdir, opts.s) then
			built = built + 1
		else
			if not opts.k then
				os.exit(1)
			end
		end
	end

	-- purge old packages
	local deleted = 0
	if opts.p then
		local keep = {}
		for aport,name in db:each() do
			keep[aport:get_apk_file_name(name)] = true
		end
		local apkrepodir = ("%s/%s/%s"):format(repodest, repo, abuild.arch)
		for file in lfs.dir(apkrepodir) do
			if file:match("%.apk$") and not keep[file] then
				print("Deleting ", file)
				if not opts.n then
					os.remove(("%s/%s"):format(apkrepodir, file))
					deleted = deleted + 1
				end
			end
		
		end
	end

	-- generate new apkindex
	if not opts.n then
		print("Updating apk index")
		apkrepo.update_index(("%s/%s"):format(repodest, repo),
				abuild.arch, db:git_describe())
	end
	stats[repo].built = built
	stats[repo].tried = tried
	stats[repo].deleted = deleted
	stats[repo].time = os.clock() - start_time
end

for repo,stat in pairs(stats) do
	print(repo.." built:", stat.built)
	print(repo.." tried:", stat.tried)
	print(repo.." deleted:", stat.deleted)
	print(repo.." time:", stat.time)
	print(repo.." total built:", stat.aports - stat.tried + stat.built)
	print(repo.." total aports:", stat.aports)
end

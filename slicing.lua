local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"

local ctx = {
    snapshot_time=-1,
    start_time = -1,
    end_time = -1
}
local o = {
    datFiles_dir= os.getenv("HOME").."/opt/mpvSlicingList",
    quickImg_dir = os.getenv("HOME").."/Nextcloud/quickImg/",
    target_dir = "{output}/",
    vcodec = "-c:v libx264", --  -crf 35
    acodec = "-c:a copy -b:a 256k",
    bv = "-b:v 2.5M",
    opts = "-speed 2 -threads 4",
    ext = "mp4",
    imgExt="jpg",
    cpuCommandTemplate = [[
        ffmpeg -v warning -y -stats
        -ss $shift -i $in $vcodec $acodec
        -t $duration
        $opts $out.$ext
    ]],
    gpuCommandTemplate=[[
        ffmpeg -v warning -y -stats
        -vsync 0 -hwaccel cuvid -hwaccel_output_format cuda
        -ss $shift -c:v h264_cuvid -i $in
        -c:v h264_nvenc $bv $acodec
        -t $duration $out.$ext
    ]],
    imgCommandTemplate=[[
        ffmpeg -v warning -y -stats
        -ss $shift -i $in -qscale:v 1 -frames:v 1
        $out.$ext
    ]]
}

local emacsParam={
    protocol="org-protocol",
    template="ab",
    img_template="ac",
    url="",
    title="",
    body=""
}

options.read_options(o)

function menu_set_time(field)
    local time,err = mp.get_property_number("time-pos")

    if time == nil or time == ctx[field] then
        ctx[field] = -1
        osd("Failed to get timestamp")
        msg.error("Failed to get timestamp: " .. err)
    else
        ctx[field] = time
    end

end

function timestamp(duration)
    local hours = math.floor(duration / 3600)
    local minutes = math.floor(duration % 3600 / 60)
    local seconds = duration % 60
    return string.format("%02d:%02d:%02.03f", hours, minutes, seconds)
end

function osd(str)
    return mp.osd_message(str, 3)
end

-- function get_homedir()
--   -- It would be better to do platform detection instead of fallback but
--   -- it's not that easy in Lua.
--   -- return os.getenv("HOME") or os.getenv("USERPROFILE") or ""
--   return os.getenv("HOME").."/opt/mpvSlicingList"
-- end

function log(str)
    local logpath = utils.join_path(o.datFiles_dir,"/log/mpv_slicing.log")
    f = io.open(logpath, "a")
    f:write(string.format("# %s\n%s\n",
        os.date("%Y-%m-%d %H:%M:%S"),
        str))
    f:close()
end

function escape(str)
    -- FIXME(Kagami): This escaping is NOT enough, see e.g.
    -- https://stackoverflow.com/a/31413730
    -- Consider using `utils.subprocess` instead.
    return str:gsub("\\", "\\\\"):gsub('"', '\\"')
end

function trim(str)
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

function get_csp()
    local csp = mp.get_property("colormatrix")
    if csp == "bt.601" then return "bt601"
        elseif csp == "bt.709" then return "bt709"
        elseif csp == "smpte-240m" then return "smpte240m"
        else
            local err = "Unknown colorspace: " .. csp
            osd(err)
            error(err)
    end
end

function get_outname(shift, endpos)
    local name = mp.get_property("filename")
    local dotidx = name:reverse():find(".", 1, true)
    if dotidx then name = name:sub(1, -dotidx-1) end
    name = name:gsub(" ", "/")
    name = name:gsub(":", "-")
    name = name:gsub("_","--")
    if endpos ~= -1 then
        name = name .. string.format(":-:%s-%s", timestamp(shift), timestamp(endpos))
    else
        name = name .. string.format(":-:%s", timestamp(shift))
    end
        return name
end

function command_writer(filename, input_string)

	local file_object = io.open(filename, 'a')

	if file_object == nil then
		msg.error('Unable to open file for appending: ' .. filename)
		return
	end

	file_object:write(input_string .. '\n')
	file_object:close()
end


function emacs(outname,vidFlag)
local ext=''
local template=''
local filetype=''
if vidFlag == 1  then
	ext = o.ext -- video file
  filetype="mpv"
    template=emacsParam.template
else
	ext = o.imgExt -- img file
  filetype="img"
    template=emacsParam.img_template
end

emacsParam.url=outname.."."..ext
emacsParam.body=outname.."."..ext
emacsParam.title="from anki notes"

local emacsCmd=[[
    "$protocol://capture?
    template=$template&
    url=$url&
    title=$title&
    body=$body"
    ]]

emacsCmd=emacsCmd:gsub("%s+","")
emacsCmd=emacsCmd:gsub("$protocol",emacsParam.protocol)
emacsCmd=emacsCmd:gsub("$template",template)
emacsCmd=emacsCmd:gsub("$title",emacsParam.title)
emacsCmd=emacsCmd:gsub("$url",emacsParam.url)
emacsCmd=emacsCmd:gsub("$body",emacsParam.body)
msg.info("emacs :: ".."emacsclient "..emacsCmd)
os.execute("emacsclient "..emacsCmd)

end

function cut(shift, endpos)
    local cpuCmd = trim(o.cpuCommandTemplate:gsub("%s+", " "))
    local gpuCmd = trim(o.gpuCommandTemplate:gsub("%s+", " "))

    local outname=get_outname(shift, endpos)

    -- local inpath = "{input}/" .. mp.get_property("stream-path")

    local inpath=string.format("%s/%s",mp.get_property("working-directory"),
                        mp.get_property("path"))

    local outpath = escape(utils.join_path(o.target_dir,outname))

    cpuCmd = cpuCmd:gsub("$shift", timestamp(shift))
    cpuCmd = cpuCmd:gsub("$duration", timestamp(endpos - shift))
    cpuCmd = cpuCmd:gsub("$vcodec", o.vcodec)
    cpuCmd = cpuCmd:gsub("$acodec", o.acodec)
    cpuCmd = cpuCmd:gsub("$bv", o.bv)
    cpuCmd = cpuCmd:gsub("$opts", o.opts)
    -- Beware that input/out filename may contain replacing patterns.
    cpuCmd = cpuCmd:gsub("$ext", o.ext)
    cpuCmd = cpuCmd:gsub("$out", outpath)
    cpuCmd = cpuCmd:gsub("$in", inpath)

    gpuCmd = gpuCmd:gsub("$shift", timestamp(shift))
    gpuCmd = gpuCmd:gsub("$duration", timestamp(endpos - shift))
    gpuCmd = gpuCmd:gsub("$acodec", o.acodec)
    gpuCmd = gpuCmd:gsub("$bv", o.bv)
    -- Beware that input/out filename may contain replacing patterns.
    gpuCmd = gpuCmd:gsub("$ext", o.ext)
    gpuCmd = gpuCmd:gsub("$out", outpath)
    gpuCmd = gpuCmd:gsub("$in", inpath)

    msg.info(string.format("Cut fragment: %s-%s", timestamp(shift), timestamp(endpos)))
    osd(string.format("Cut fragment: %s-%s", timestamp(shift), timestamp(endpos)))

    emacs(outname,1)
    -- msg.info(cpuCmd)
    -- log(cpuCmd)
    -- print("start :: " .. shift)
    -- print("end :: " .. endpos)
    -- print(cpuCmd)
    -- os.execute(cpuCmd)
    mp.register_script_message("write_to_file",
        command_writer(o.datFiles_dir.."/cpuList.dat",cpuCmd))

    mp.register_script_message("write_to_file",
        command_writer(o.datFiles_dir.."/gpuList.dat",gpuCmd))
end

function snapshot(quickFlag)
    local outpath=''
    local imgCmd = trim(o.imgCommandTemplate:gsub("%s+", " "))

    local outname=get_outname(ctx.snapshot_time, -1)

    -- local inpath = "{input}/" .. mp.get_property("stream-path")

    local inpath=string.format("%s/%s",mp.get_property("working-directory"),
                        mp.get_property("path"))
    outpath = escape(utils.join_path(o.target_dir,outname))


    imgCmd = imgCmd:gsub("$shift",timestamp(ctx.snapshot_time))
    imgCmd = imgCmd:gsub("$ext", o.imgExt)
    imgCmd = imgCmd:gsub("$in", inpath)

    if (quickFlag) then
      local quickImgCmd = imgCmd
      local quickOutPath = escape(utils.join_path(o.quickImg_dir,outname))
      quickImgCmd = quickImgCmd:gsub("$out", quickOutPath)
      -- msg.info(imgCmd)
      os.execute(quickImgCmd)
    end

    imgCmd = imgCmd:gsub("$out", outpath)
    mp.register_script_message("write_to_file",
        command_writer(o.datFiles_dir.."/imgList.dat",imgCmd))

    emacs(outname,0)
end


function toggle_mark()
    local shift=ctx.start_time
    local endpos=ctx.end_time

    if shift > endpos then
        shift, endpos = endpos, shift
    end
    if shift == endpos then
        osd("Cut fragment is empty")
    else
        mp.set_property_native("pause",true)
        os.execute("wmctrl -R emacs")
        cut(shift, endpos)
    end
end

function slicing_start()
    menu_set_time('start_time')
    osd(string.format("Slicing start at: %s", timestamp(ctx.start_time)))
    msg.info(string.format("Slicing start at: %s", timestamp(ctx.start_time)))
end

function slicing_end()
    menu_set_time('end_time')
    osd(string.format("Slicing end at: %s", timestamp(ctx.end_time)))
    msg.info(string.format("Slicing end at: %s", timestamp(ctx.end_time)))
end

function take_snapshot()
    menu_set_time('snapshot_time')
    osd(string.format("snapshot at: %s", timestamp(ctx.snapshot_time)))
    msg.info(string.format("snapshot at: %s", timestamp(ctx.snapshot_time)))
    mp.set_property_native("pause",true)
    os.execute("wmctrl -R emacs")
    snapshot(false)
end

function quick_snapshot()
    menu_set_time('snapshot_time')
    osd(string.format("snapshot at: %s", timestamp(ctx.snapshot_time)))
    -- msg.info(string.format("snapshot at: %s", timestamp(ctx.snapshot_time)))
    mp.set_property_native("pause",true)
    os.execute("wmctrl -R emacs")
    snapshot(true)
end


mp.add_key_binding("c", "slicing_start", slicing_start)
mp.add_key_binding("shift+c", "slicing_end", slicing_end)
mp.add_key_binding("ctrl+c", "slicing_mark", toggle_mark)
mp.add_key_binding("ctrl+s", "quick_snapshot", quick_snapshot)
mp.add_key_binding("ctrl+shift+s", "taking_snapshot", take_snapshot)

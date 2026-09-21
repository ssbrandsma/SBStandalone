local setmetatable, tostring = setmetatable, tostring
local string = require("string")
local RequestHttp = require("jive.net.RequestHttp")
local Resolver = require("applets.StandaloneRadio.Resolver")
local SocketHttp = require("jive.net.SocketHttp")
local jnt = jnt
module(...)
local ArtworkRequest = {}; ArtworkRequest.__index = ArtworkRequest
local function enc(v) return (string.gsub(tostring(v or ""), "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end)) end
function new(o)
 local h,p,path=string.match(o.baseUrl or "http://49.12.198.91:9000/artwork", "^http://([%w%.%-]+):?(%d*)(/.*)$")
 return setmetatable({log=o.log,host=h,port=tonumber(p) or 9000,path=path or "/artwork",resolver=Resolver.new({log=o.log})},ArtworkRequest)
end
function ArtworkRequest:fetch(p, cb)
 if not self.host then cb(nil,"invalid artwork URL"); return end
 local q="?type="..enc(p.type); for _,k in ipairs({"stationuuid","artist","title"}) do if p[k] then q=q.."&"..k.."="..enc(p[k]) end end
 self.resolver:resolve(self.host,function(ip)
  if not ip then cb(nil,"artwork DNS failed"); return end
  local r=RequestHttp(function(body,err) if body or err then cb(body,err) end end,"GET",self.path..q,{headers={Host=self.host,Accept="image/png,image/jpeg",Connection="close"}})
  local h=SocketHttp(jnt,ip,self.port,"StandaloneRadioArtwork"); h.t_getSendHeaders=function() return { ["User-Agent"]="StandaloneRadio/0.7.3" } end; h:fetch(r)
 end)
end

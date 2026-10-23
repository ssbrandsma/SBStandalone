-- UI adapter injection keeps navigation independent of a provider and Jive.
local M={}
local Navigator={};Navigator.__index=Navigator
function M.new(options)
    return setmetatable({client=options.client,ui=options.ui,serial=0,contexts={},clock=options.clock or os.time,cacheTtl=options.cacheTtl},Navigator)
end
function Navigator:cancel()
    self.serial=self.serial+1
    if self.pending then self.pending() end
    self.pending=nil
end
function Navigator:close()
    self:cancel()
    for context in pairs(self.contexts) do
        context.active=false
        if context.menu then context.menu:setItems({}) end
        context.menu=nil
    end
    self.contexts={}
end
function Navigator:items(entries)
    local items={}
    for index,entry in ipairs(entries or {}) do
        local selected=entry
        local item={text=selected.title and selected.title~="" and selected.title or selected.guide_id or selected.id or self.ui.text("untitled"),sound="SELECT",weight=index}
        if index<=24 and self.ui.icon and (selected.image or selected.icon) then item.icon=self.ui.icon(selected) end
        if selected.type=="audio" and self.ui.actions then
            item.cmCallback=function()
                local station,err=self.client:toStation(selected)
                if station then self.ui.actions(station) else self.ui.error(err) end
            end
        end
        if selected.type=="search" and selected.url then
            item.callback=function() self:search(selected) end
        elseif selected.type=="audio" and selected.url then
            item.callback=function()
                local station,err=self.client:toStation(selected)
                if station then self.ui.play(station) else self.ui.error(err) end
            end
        elseif selected.children or (selected.type=="directory" and not selected.url) then
            item.callback=function() self:open(nil,selected.title,selected.children or {}) end
        elseif selected.url and (selected.type=="link" or selected.type=="directory" or selected.type=="") then
            item.callback=function() self:open(selected.url,selected.title) end
        else item.style="item" end
        items[#items+1]=item
    end
    if #items==0 then items[1]={text=self.ui.text("empty"),style="item",weight=0} end
    return items
end
function Navigator:search(entry)
    entry=entry or {title=self.ui.text("search"),url=self.client:searchUrl()}
    self:cancel()
    self.current=nil -- The keyboard deactivates its parent window.
    local identity=self.serial
    self.ui.search(entry,function(url) if identity==self.serial then self:open(url,entry.title,nil,true) end end,
        function() if identity==self.serial then self:cancel() end end)
end
function Navigator:open(url,title,inline,search)
    local depth=0
    for _ in pairs(self.contexts) do depth=depth+1 end
    if depth>=12 then self.ui.error("OPML navigation depth limit reached");return nil end
    if url then
        for ancestor in pairs(self.contexts) do
            if ancestor.url==url or ancestor.effectiveUrl==url then self.ui.error("Circular OPML directory link");return nil end
        end
    end
    self:cancel()
    local window,menu=self.ui.window(title)
    self.openSerial=(self.openSerial or 0)+1
    local context={active=true,menu=menu,order=self.openSerial,remote=url~=nil,url=url}
    self.contexts[context]=true
    local function deactivate()
        if context.active then
            context.active=false
            if self.current==context then self:cancel() end
        end
    end
    self.ui.listen(window,deactivate,function()
        deactivate();self.contexts[context]=nil
        if self.current==context then self.current=nil end
        if context.menu then context.menu:setItems({}) end
        context.menu=nil
    end,function() if context.resume then context.resume() end end)
    local root=self.client:searchUrl() and url==self.client:rootUrl()
    local function decorate(items)
        if root then table.insert(items,1,{text=self.ui.text("search"),sound="SELECT",weight=-1,callback=function() self:search() end}) end
        return items
    end
    local function load()
        self:cancel();context.active=true;self.current=context
        context.loading=true
        local identity=self.serial
        context.menu:setItems(decorate({{text=self.ui.text("loading"),style="item",weight=0}}))
        local finished=false
        local cancel=self.client:fetchDirectory(url,function(directory,err)
            if identity~=self.serial or not context.active or not context.menu then return end
            finished=true;self.pending=nil;context.loading=false
            if directory and directory.url then
                for ancestor in pairs(self.contexts) do
                    if ancestor~=context and (ancestor.url==directory.url or ancestor.effectiveUrl==directory.url) then directory=nil;err="Circular OPML directory redirect";break end
                end
            end
            if not directory then
                context.menu:setItems(decorate({{text=self.ui.text("failed"),weight=0,callback=load}}))
                self.ui.error(err,true)
            else
                context.loaded=true;context.loadedAt=self.clock();context.effectiveUrl=directory.url
                local entries={}
                for _,entry in ipairs(directory.children or {}) do
                    if not (root and entry.type=="search") then entries[#entries+1]=entry end
                end
                if search then
                    local stations={}
                    local function collect(children)
                        for _,entry in ipairs(children) do
                            if entry.type=="audio" then local station=self.client:toStation(entry);if station then stations[#stations+1]=station end
                            elseif entry.children then collect(entry.children) end
                        end
                    end
                    collect(entries);context.menu:setItems(self.ui.stations(stations))
                else context.menu:setItems(decorate(self:items(entries))) end
                -- Keep at most two remote menu payloads. Older Back targets
                -- retain only navigation state and reload when activated.
                local loaded={}
                for older in pairs(self.contexts) do
                    if older.remote and older.loaded then loaded[#loaded+1]=older end
                end
                table.sort(loaded,function(a,b) return a.order<b.order end)
                local excess=#loaded-2
                for _,older in ipairs(loaded) do
                    if excess>0 and older~=context and older.menu then
                        older.menu:setItems({{text=self.ui.text("loading"),style="item",weight=0}})
                        older.loaded=false;older.loading=true
                        excess=excess-1
                    end
                end
            end
            context.menu:reLayout()
        end)
        if not finished and type(cancel)=="function" then self.pending=cancel end
    end
    context.resume=function()
        if not context.active and url and (context.loading or (self.cacheTtl and context.loadedAt and (self.clock()<context.loadedAt or self.clock()-context.loadedAt>=self.cacheTtl))) then load()
        else context.active=true;self.current=context end
    end
    self.ui.show(window)
    if inline then menu:setItems(self:items(inline)) else load() end
    return window
end
return M

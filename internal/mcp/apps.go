package mcp

import (
	"context"
	"net/url"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/uvwt/agentdock/internal/app"
)

const mcpAppMIMEType = "text/html;profile=mcp-app"

type appResourceDefinition struct {
	URI         string
	Name        string
	Title       string
	Description string
	HTML        string
}

func (s *Server) registerAppResources() {
	widgetDomain := appWidgetDomain(s.cfg.OAuthServerURL)
	definitions := []appResourceDefinition{
		{
			URI:         app.AgentContextUIResourceURI,
			Name:        "agentdock-context",
			Title:       "AgentDock context",
			Description: "Compact read-only AgentDock capability summary with expandable bootstrap context.",
			HTML:        mcpAppHTML("agentdock_context", "AgentDock context"),
		},
		{
			URI:         app.TaskProgressUIResourceURI,
			Name:        "agentdock-task-progress",
			Title:       "AgentDock task",
			Description: "Compact read-only task lifecycle view for task_manage results and task snapshots.",
			HTML:        mcpAppHTML("task_progress", "Task"),
		},
		{
			URI:         app.FileChangeUIResourceURI,
			Name:        "agentdock-file-change",
			Title:       "AgentDock file change",
			Description: "Read-only view of the file_edit result, including diff preview and file operation summary.",
			HTML:        mcpAppHTML("file_change", "File change"),
		},
	}
	if s.cfg.ACPEnabled {
		definitions = append(definitions, appResourceDefinition{
			URI:         app.ACPStatusUIResourceURI,
			Name:        "agentdock-acp-status",
			Title:       "AgentDock ACP conversation",
			Description: "Read-only ACP session view with concise user and assistant conversation output.",
			HTML:        mcpAppHTML("acp_status", "ACP status"),
		})
	}

	for _, definition := range definitions {
		definition := definition
		meta := appResourceMeta(widgetDomain)
		s.sdk.AddResource(&mcpsdk.Resource{
			URI:         definition.URI,
			Name:        definition.Name,
			Title:       definition.Title,
			Description: definition.Description,
			MIMEType:    mcpAppMIMEType,
			Meta:        meta,
		}, func(_ context.Context, request *mcpsdk.ReadResourceRequest) (*mcpsdk.ReadResourceResult, error) {
			if request == nil || request.Params == nil || request.Params.URI != definition.URI {
				return nil, mcpsdk.ResourceNotFoundError(definition.URI)
			}
			return &mcpsdk.ReadResourceResult{Contents: []*mcpsdk.ResourceContents{{
				URI:      definition.URI,
				MIMEType: mcpAppMIMEType,
				Text:     definition.HTML,
				Meta:     appResourceMeta(widgetDomain),
			}}}, nil
		})
	}
}

func appResourceMeta(widgetDomain string) mcpsdk.Meta {
	ui := map[string]any{
		"csp": map[string]any{
			"connectDomains":  []string{},
			"resourceDomains": []string{},
		},
		"prefersBorder": true,
	}
	if widgetDomain != "" {
		ui["domain"] = widgetDomain
	}
	return mcpsdk.Meta{"ui": ui}
}

func appWidgetDomain(serverURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(serverURL))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return ""
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return ""
	}
	return "https://" + parsed.Host
}

func mcpAppHTML(view, title string) string {
	return strings.NewReplacer("{{VIEW}}", view, "{{TITLE}}", title).Replace(mcpAppHTMLTemplate)
}

const mcpAppHTMLTemplate = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'none'">
<title>{{TITLE}}</title>
<style>
:root{color-scheme:light;font:13px/1.45 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}body{margin:0;padding:0;background:transparent;color:#111}main{background:transparent;color:#111}.compact-toggle{width:100%;min-height:64px;border:0;border-radius:0;padding:10px 14px;background:transparent;color:#111;display:grid;grid-template-columns:minmax(0,1fr) auto;grid-template-rows:auto auto;gap:6px 12px;align-items:center;text-align:left;font:inherit;cursor:pointer}.compact-toggle:hover{background:#fafafa}.compact-toggle.single-line{min-height:42px;grid-template-rows:auto;padding-top:8px;padding-bottom:8px}.compact-primary{display:flex;min-width:0;gap:7px;align-items:center}.compact-action{flex:0 0 auto;font-size:11px;font-weight:800;letter-spacing:.04em;text-transform:uppercase}.compact-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.compact-secondary{grid-column:1/-1;min-width:0;display:flex;gap:12px;align-items:center}.compact-middle{flex:1 1 52%;min-width:120px}.compact-meta{min-width:0;font-size:11px;color:#666;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.compact-secondary>.compact-meta{flex:1 1 auto;text-align:right}.compact-end{display:flex;align-items:center;gap:8px;white-space:nowrap}.brand{font-weight:800;letter-spacing:.01em}.chevron{width:8px;height:8px;border-right:1.5px solid #555;border-bottom:1.5px solid #555;transform:rotate(45deg);transition:transform .15s ease;margin:-3px 2px 0 0}.expanded .chevron{transform:rotate(225deg);margin:3px 2px 0 0}.detail-panel{border-top:1px solid #ececec;padding:12px 14px 14px;background:transparent}.detail-panel[hidden]{display:none}.headline{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0 0 8px}.action{font-weight:800;letter-spacing:.035em;text-transform:uppercase;color:#111}.path{min-width:0;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#111;overflow-wrap:anywhere}.arrow{color:#666}.meta{display:flex;flex-wrap:wrap;gap:10px;margin:0 0 8px;font-size:11px;color:#666}.summary{margin:6px 0 0;white-space:pre-wrap;color:#222}.empty{padding:4px 0;color:#666}
.compact-progress{position:relative;height:16px;display:flex;align-items:center;justify-content:space-between;padding:0 4px}.compact-progress::before{content:"";position:absolute;left:7px;right:7px;top:50%;height:1px;background:#d7d7d7;transform:translateY(-50%)}.progress-fill{position:absolute;z-index:0;left:7px;top:50%;height:1.5px;background:#111;transform:translateY(-50%)}.progress-node{position:relative;z-index:1;width:9px;height:9px;border:1.5px solid #aaa;border-radius:50%;background:#fff}.progress-node.completed{border-color:#111;background:#111}.progress-node.in-progress{border-color:#111;box-shadow:0 0 0 2px #fff,0 0 0 3px #111}.progress-node.blocked{border-color:#555;background:#fff}.steps{position:relative;display:grid;gap:0;margin-top:9px}.steps::before{content:"";position:absolute;left:9px;top:10px;bottom:10px;width:1px;background:#ddd}.step{position:relative;display:grid;grid-template-columns:20px minmax(0,1fr) auto;gap:8px;align-items:center;padding:6px 0}.step-marker{position:relative;z-index:1;width:19px;height:19px;border:1px solid #bbb;border-radius:50%;display:grid;place-items:center;background:#fff;color:#666;font:700 11px/1 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.step.completed .step-marker{border-color:#111;background:#111;color:#fff}.step.in-progress .step-marker{border-color:#111;color:#111}.step.blocked .step-marker{border-color:#777;color:#444}.step-title,.row-title{min-width:0;color:#111}.step-status,.row-status{font-size:11px;color:#666}.rows{display:grid;gap:0;margin-top:8px;border-top:1px solid #eee}.row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;padding:7px 0;border-bottom:1px solid #eee}.row-sub{grid-column:1/-1;font-size:11px;color:#666;margin-top:-4px}
pre{margin:8px 0 0;max-height:420px;overflow:auto;border-top:1px solid #eee;padding:8px 0 0;background:#fff;color:#111;font:11.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}.diff-line{display:block;min-height:1.45em;padding:0 4px;color:#111}.diff-context{color:#555}.diff-add{color:#315b45;background:#f5fbf7}.diff-del{color:#7a3e39;background:#fff7f6}.messages{display:grid;gap:10px;margin-top:10px}.message{border-left:2px solid #ddd;padding-left:9px}.message.user{border-left-color:#111}.message.assistant{border-left-color:#888}.message-role{margin-bottom:2px;font-size:10px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#666}.message-text{white-space:pre-wrap;overflow-wrap:anywhere;color:#111}.kv{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:5px 10px;margin-top:8px}.kv-key{font-size:11px;color:#666}.kv-value{min-width:0;color:#111;overflow-wrap:anywhere}.context-stats{display:flex;flex-wrap:wrap;gap:18px;padding:2px 0 12px;border-bottom:1px solid #eee}.context-stat{min-width:72px}.context-stat-value{font-size:18px;font-weight:750;line-height:1.1}.context-stat-label{margin-top:3px;font-size:10px;color:#666;text-transform:uppercase;letter-spacing:.05em}.context-section{padding-top:12px}.context-section-head{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:6px}.context-section-title{font-weight:750}.context-section-count{font-size:11px;color:#777}.context-list{display:grid;gap:0;border-top:1px solid #eee}.context-item{display:grid;grid-template-columns:minmax(110px,180px) minmax(0,1fr);gap:12px;padding:7px 0;border-bottom:1px solid #eee}.context-name{font-weight:650;overflow-wrap:anywhere}.context-desc{min-width:0;color:#555;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}.context-more{padding:7px 0;color:#777;font-size:11px}
@media(max-width:560px){.compact-toggle{grid-template-columns:minmax(0,1fr) auto;padding:9px 12px}.compact-secondary{gap:8px}.compact-middle{min-width:96px}.compact-secondary>.compact-meta{text-align:left}.context-item{grid-template-columns:1fr;gap:2px}.context-stats{gap:12px}}
</style>
</head>
<body>
<main><div id="content" class="empty">Waiting for tool output…</div></main>
<script>
(()=>{
  "use strict";
  const expectedView="{{VIEW}}";
  const root=document.getElementById("content");
  let lastSerialized="";
  let rpcID=0;
  let lastReportedHeight=0;
  let resizeObserver=null;
  const pendingRequests=new Map();

  const el=(tag,className,text)=>{const node=document.createElement(tag);if(className)node.className=className;if(text!==undefined)node.textContent=String(text);return node};
  const isObject=value=>value!==null&&typeof value==="object"&&!Array.isArray(value);
  const scalar=value=>value===null||["string","number","boolean"].includes(typeof value);
  const actionLabel=value=>String(value||"").replaceAll("_"," ").toUpperCase();
  const rpcNotify=(method,params)=>window.parent.postMessage({jsonrpc:"2.0",method,params:params||{}},"*");
  const rpcRequest=(method,params)=>new Promise((resolve,reject)=>{
    const id=++rpcID;
    pendingRequests.set(id,{resolve,reject});
    window.parent.postMessage({jsonrpc:"2.0",id,method,params:params||{}},"*");
  });

  function reportSize(){
    const html=document.documentElement;
    const originalHeight=html.style.height;
    html.style.height="max-content";
    const height=Math.ceil(html.getBoundingClientRect().height);
    html.style.height=originalHeight;
    if(!height||height===lastReportedHeight)return;
    lastReportedHeight=height;
    rpcNotify("ui/notifications/size-changed",{height});
  }

  function startAutoResize(){
    if(typeof ResizeObserver!=="undefined"){
      resizeObserver=new ResizeObserver(reportSize);
      resizeObserver.observe(document.body);
      resizeObserver.observe(document.documentElement);
    }
    requestAnimationFrame(reportSize);
  }

  function compactShell(primary,middle,meta,details){
    const wrapper=el("div","app-shell");
    const toggle=el("button","compact-toggle");
    toggle.type="button";toggle.setAttribute("aria-expanded","false");
    const primaryWrap=el("span","compact-primary");
    if(primary.action)primaryWrap.append(el("strong","compact-action",actionLabel(primary.action)));
    primaryWrap.append(el("span","compact-title",primary.title||"AgentDock"));
    toggle.append(primaryWrap);
    const end=el("span","compact-end");
    end.append(el("span","brand","AgentDock"));end.append(el("span","chevron"));toggle.append(end);
    if(middle||meta){
      const secondary=el("span","compact-secondary");
      if(middle){middle.classList.add("compact-middle");secondary.append(middle)}
      if(meta)secondary.append(el("span","compact-meta",meta));
      toggle.append(secondary);
    }else{
      toggle.classList.add("single-line");
    }
    const panel=el("div","detail-panel");panel.hidden=true;panel.append(details);
    toggle.addEventListener("click",()=>{const expanded=toggle.getAttribute("aria-expanded")==="true";toggle.setAttribute("aria-expanded",String(!expanded));toggle.classList.toggle("expanded",!expanded);panel.hidden=expanded;requestAnimationFrame(reportSize)});
    wrapper.append(toggle,panel);root.replaceChildren(wrapper);
  }

  function taskProgress(steps){
    if(!steps.length)return null;
    const progress=el("span","compact-progress");
    let reached=-1,index=0;
    for(const step of steps){
      if(!isObject(step))continue;
      const status=String(step.status||"pending");
      const statusClass=status==="in_progress"?"in-progress":status;
      if(status==="completed"||status==="in_progress"||status==="blocked")reached=index;
      const node=el("span","progress-node "+statusClass);
      node.title=(step.title||step.id||"Step")+" · "+status;
      progress.append(node);index++;
    }
    if(!index)return null;
    const fill=el("span","progress-fill");
    const ratio=index===1?(reached===0?1:0):Math.max(0,reached)/(index-1);
    fill.style.width="calc((100% - 14px) * "+ratio+")";
    progress.prepend(fill);
    return progress;
  }

  function headline(fragment,action,primary,secondary){
    const line=el("div","headline");
    line.append(el("strong","action",actionLabel(action)||"STATUS"));
    if(primary)line.append(el("span","path",primary));
    if(secondary){line.append(el("span","arrow","→"));line.append(el("span","path",secondary))}
    fragment.append(line);
  }

  function metaLine(fragment,values){
    const valuesClean=values.filter(value=>value!==undefined&&value!==null&&value!=="");
    if(!valuesClean.length)return;
    const meta=el("div","meta");
    for(const value of valuesClean)meta.append(el("span","",value));
    fragment.append(meta);
  }

  function appendDiffPreview(fragment,diff){
    const pre=el("pre");
    let shown=0;
    for(const line of String(diff||"").split("\n")){
      if(line.startsWith("--- ")||line.startsWith("+++ ")||line.startsWith("@@")||line==="\\ No newline at end of file")continue;
      if(!line&&shown===0)continue;
      let cls="diff-line diff-context";
      if(line.startsWith("+"))cls="diff-line diff-add";else if(line.startsWith("-"))cls="diff-line diff-del";
      pre.append(el("span",cls,line+"\n"));shown++;
    }
    if(shown)fragment.append(pre);
  }

  function taskRecord(data){
    if(isObject(data.task))return data.task;
    if(isObject(data.task_summary))return data.task_summary;
    return {};
  }

  function contextSectionLines(text,title){
    const lines=String(text||"").split("\n");
    const items=[];let active=false;
    for(const raw of lines){
      const line=raw.trim();
      if(line.startsWith("## ")){
        if(active)break;
        active=line==="## "+title;
        continue;
      }
      if(!active||!line.startsWith("- "))continue;
      if(line.includes("当前没有")||line.includes("暂不可用"))continue;
      items.push(line.slice(2).trim());
    }
    return items;
  }

  function contextNamedItems(text,title){
    return contextSectionLines(text,title).map(line=>{
      const named=line.match(/^name:\s*([^;]+)(?:;\s*description:\s*([^;]*))?/);
      if(named)return{name:named[1].trim(),description:(named[2]||"").trim()};
      const agent=line.match(/^agent:\s*(.+)$/);
      if(agent)return{name:agent[1].trim(),description:"ACP agent"};
      const separator=line.indexOf("：");
      if(separator>0)return{name:line.slice(0,separator).trim(),description:line.slice(separator+1).trim()};
      return{name:line,description:""};
    });
  }

  function appendContextStat(parent,value,label){
    const stat=el("div","context-stat");
    stat.append(el("div","context-stat-value",value),el("div","context-stat-label",label));
    parent.append(stat);
  }

  function appendContextSection(parent,title,items,limit){
    if(!items.length)return;
    const section=el("section","context-section");
    const head=el("div","context-section-head");
    head.append(el("div","context-section-title",title),el("div","context-section-count",String(items.length)));
    section.append(head);
    const list=el("div","context-list");
    for(const item of items.slice(0,limit)){
      const row=el("div","context-item");
      row.append(el("div","context-name",item.name||"Item"));
      row.append(el("div","context-desc",item.description||"Available"));
      list.append(row);
    }
    if(items.length>limit)list.append(el("div","context-more","还有 "+(items.length-limit)+" 项"));
    section.append(list);parent.append(section);
  }

  function renderAgentContext(data){
    const text=String(data.context||"");
    const fragment=document.createDocumentFragment();
    const skills=contextNamedItems(text,"Skill 能力索引");
    const mcps=contextNamedItems(text,"动态 MCP 索引");
    const acp=contextNamedItems(text,"ACP 运行时");
    const workflows=contextNamedItems(text,"工作流模板索引");
    const recall=text.includes("## 记忆精简摘要");
    const stats=el("div","context-stats");
    appendContextStat(stats,skills.length,"Skills");
    appendContextStat(stats,mcps.length,"MCP");
    appendContextStat(stats,workflows.length,"Workflow");
    appendContextStat(stats,recall?"ON":"OFF","Recall");
    fragment.append(stats);
    appendContextSection(fragment,"Skills",skills,12);
    appendContextSection(fragment,"MCP",mcps,8);
    appendContextSection(fragment,"ACP",acp,4);
    appendContextSection(fragment,"Workflow",workflows,10);
    const summary=[skills.length+" Skills",mcps.length+" MCP",workflows.length+" Workflow",recall?"Recall":"No Recall"];
    compactShell({action:"context",title:"AgentDock Context"},null,summary.join(" · "),fragment);
  }

  function renderTask(data){
    const fragment=document.createDocumentFragment();
    if(Array.isArray(data.tasks)){
      const count=Number(data.count??data.tasks.length);
      headline(fragment,data.action||"list",String(count)+" tasks");
      const rows=el("div","rows");
      for(const task of data.tasks){
        if(!isObject(task))continue;
        const row=el("div","row");
        row.append(el("div","row-title",task.title||task.id||"Task"));
        row.append(el("div","row-status",task.status||""));
        const current=isObject(task.current_step)?task.current_step:null;
        if(current)row.append(el("div","row-sub",current.title||current.id||""));
        rows.append(row);
      }
      if(rows.childNodes.length)fragment.append(rows);else fragment.append(el("div","empty","No tasks."));
      const first=data.tasks.find(task=>isObject(task));
      const current=first&&isObject(first.current_step)?first.current_step:null;
      const listMeta=current?(current.title||current.id||""):first?(first.status||""):"";
      compactShell({action:data.action||"list",title:String(count)+" tasks"},null,listMeta,fragment);return;
    }

    const task=taskRecord(data);
    const title=task.title||task.id||data.task_id||"Task";
    const completed=Number(task.completed_step_count||0),total=Number(task.step_count||0);
    let steps=Array.isArray(task.steps)?task.steps:[];
    if(!steps.length&&isObject(task.current_step))steps=[task.current_step];
    headline(fragment,data.action||"task",title);
    metaLine(fragment,[task.status||task.phase||data.review_status,total>0?completed+" / "+total+" steps":"",data.final_review&&data.final_review.status?"review "+data.final_review.status:""]);
    if(typeof task.summary==="string"&&task.summary)fragment.append(el("p","summary",task.summary));
    if(steps.length){const list=el("div","steps");for(const step of steps){if(!isObject(step))continue;const status=String(step.status||"pending");const statusClass=status==="in_progress"?"in-progress":status;const row=el("div","step "+statusClass);const marker=el("div","step-marker",status==="completed"?"✓":status==="in_progress"?"●":status==="blocked"?"!":"");row.append(marker);row.append(el("div","step-title",step.title||step.id||"Step"));row.append(el("div","step-status",status));list.append(row)}fragment.append(list)}
    const activeStep=steps.find(step=>isObject(step)&&(step.status==="in_progress"||step.status==="blocked"))||(isObject(task.current_step)?task.current_step:null);
    const compactMeta=[activeStep?(activeStep.title||activeStep.id||""):"",total>0?completed+" / "+total:task.status||task.phase||""].filter(Boolean).join(" · ");
    compactShell({action:data.action||"task",title},taskProgress(steps),compactMeta,fragment);
  }

  function renderFileChange(data){
    const fragment=document.createDocumentFragment();
    const primary=data.path||data.workdir||"";
    headline(fragment,data.action||"change",primary,data.action==="move"?data.new_path:"");
    const insertions=Number.isFinite(Number(data.insertions))?"+"+Number(data.insertions):"";
    const deletions=Number.isFinite(Number(data.deletions))?"−"+Number(data.deletions):"";
    metaLine(fragment,[data.dry_run===true?"dry run":"",data.changed===false?"no change":"",insertions,deletions,data.truncated===true?"preview truncated":""]);
    if(typeof data.diff_preview==="string"&&data.diff_preview)appendDiffPreview(fragment,data.diff_preview);
    else if(data.changed===false)fragment.append(el("div","empty","No change."));
    compactShell({action:data.action||"change",title:primary||"File change"},null,[insertions,deletions].filter(Boolean).join("  "),fragment);
  }

  function acpSessionID(state){
    if(state.session_id)return state.session_id;
    if(isObject(state.session))return state.session.id||state.session.session_id||"";
    return "";
  }

  function renderACP(data){
    const state=isObject(data.state)?data.state:data;
    const fragment=document.createDocumentFragment();
    if(Array.isArray(state.sessions)){
      headline(fragment,state.action||"list",String(state.count??state.sessions.length)+" sessions");
      const rows=el("div","rows");
      for(const session of state.sessions){
        if(!isObject(session))continue;
        const row=el("div","row");
        row.append(el("div","row-title",session.id||session.session_id||"Session"));
        row.append(el("div","row-status",session.status||""));
        if(session.cwd)row.append(el("div","row-sub",session.cwd));
        rows.append(row);
      }
      if(rows.childNodes.length)fragment.append(rows);else fragment.append(el("div","empty","No ACP sessions."));
      const first=state.sessions.find(session=>isObject(session));
      const listMeta=first?[first.status||"",first.agent||"",first.cwd||""].filter(Boolean).join(" · "):"";
      compactShell({action:state.action||"list",title:String(state.count??state.sessions.length)+" sessions"},null,listMeta,fragment);return;
    }
    const session=isObject(state.session)?state.session:{};
    const identity=acpSessionID(state)||(isObject(state.agent)?state.agent.name||state.agent.title:"")||"ACP";
    headline(fragment,state.action||"status",identity);
    metaLine(fragment,[session.status||state.status,state.authenticated===true?"authenticated":"",session.agent||"",session.mode_id||state.mode_id||"",state.deleted===true?"deleted":""]);
    if(session.cwd)fragment.append(el("div","path",session.cwd));
    if(Array.isArray(state.messages)){
      const messages=el("div","messages");
      for(const message of state.messages){
        if(!isObject(message)||(message.role!=="user"&&message.role!=="assistant")||typeof message.content!=="string"||!message.content)continue;
        const item=el("div","message "+message.role);
        item.append(el("div","message-role",message.role));
        item.append(el("div","message-text",message.content));
        messages.append(item);
      }
      if(messages.childNodes.length)fragment.append(messages);else fragment.append(el("div","empty","No user or assistant messages in this AgentDock process."));
      compactShell({action:state.action||"status",title:identity},null,session.status||state.status||"",fragment);return;
    }
    if(state.message)fragment.append(el("p","summary",state.message));
    if(!isObject(state.session)&&!Array.isArray(state.sessions)){
      const important=["protocol_version","run_id","stop_reason","count","config_id"];
      const grid=el("div","kv");let count=0;
      for(const key of important){if(!scalar(state[key])||state[key]===undefined||state[key]===null||state[key]==="")continue;grid.append(el("div","kv-key",key));grid.append(el("div","kv-value",state[key]));count++}
      if(count)fragment.append(grid);
    }
    compactShell({action:state.action||"status",title:identity},null,session.status||state.status||"",fragment);
  }

  function renderable(data){
    if(!isObject(data))return false;
    if(data.view)return data.view===expectedView;
    if(expectedView==="agentdock_context")return typeof data.context==="string"&&data.context!=="";
    if(expectedView==="file_change")return typeof data.action==="string"&&(data.path||data.workdir||data.changed!==undefined);
    if(expectedView==="task_progress")return typeof data.action==="string"&&(isObject(data.task)||isObject(data.task_summary)||Array.isArray(data.tasks)||data.task_id);
    if(expectedView==="acp_status")return typeof data.action==="string"&&(isObject(data.session)||Array.isArray(data.sessions)||data.session_id||isObject(data.agent)||data.authenticated!==undefined||data.deleted!==undefined);
    return false;
  }

  function render(data){
    if(!renderable(data))return;
    const serialized=JSON.stringify(data);if(serialized===lastSerialized)return;lastSerialized=serialized;
    if(expectedView==="agentdock_context")renderAgentContext(data);else if(expectedView==="task_progress")renderTask(data);else if(expectedView==="file_change")renderFileChange(data);else renderACP(data);
    requestAnimationFrame(reportSize);
  }

  window.addEventListener("message",event=>{
    if(event.source!==window.parent)return;
    const message=event.data;
    if(!isObject(message)||message.jsonrpc!=="2.0")return;

    if(message.id!==undefined&&!message.method){
      const pending=pendingRequests.get(message.id);
      if(!pending)return;
      pendingRequests.delete(message.id);
      if(message.error)pending.reject(message.error);else pending.resolve(message.result);
      return;
    }

    if(message.method==="ui/notifications/tool-result"){
      const data=message.params&&message.params.structuredContent;
      if(isObject(data))render(data);
    }
  },{passive:true});

  async function initializeBridge(){
    try{
      await rpcRequest("ui/initialize",{
        appInfo:{name:"agentdock-"+expectedView,version:"1.0.0"},
        appCapabilities:{},
        protocolVersion:"2026-01-26"
      });
      rpcNotify("ui/notifications/initialized",{});
      startAutoResize();
    }catch(_){
      root.textContent="Unable to initialize MCP App.";
    }
  }

  initializeBridge();
})();
</script>
</body>
</html>`

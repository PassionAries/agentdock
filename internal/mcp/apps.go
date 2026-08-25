package mcp

import (
	"context"
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
	definitions := []appResourceDefinition{
		{
			URI:         app.TaskProgressUIResourceURI,
			Name:        "agentdock-task-progress",
			Title:       "AgentDock task progress",
			Description: "Compact read-only progress view for an AgentDock recoverable task snapshot.",
			HTML:        mcpAppHTML("task_progress", "Task progress"),
		},
		{
			URI:         app.FileDiffUIResourceURI,
			Name:        "agentdock-file-diff",
			Title:       "AgentDock file diff",
			Description: "Read-only unified diff viewer for data already returned by an AgentDock tool.",
			HTML:        mcpAppHTML("file_diff", "File diff"),
		},
	}
	if s.cfg.ACPEnabled {
		definitions = append(definitions, appResourceDefinition{
			URI:         app.ACPStatusUIResourceURI,
			Name:        "agentdock-acp-status",
			Title:       "AgentDock ACP status",
			Description: "Read-only status view for an already-fetched ACP session, prompt run, or permission interaction.",
			HTML:        mcpAppHTML("acp_status", "ACP status"),
		})
	}

	for _, definition := range definitions {
		definition := definition
		meta := appResourceMeta(definition.Description)
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
				Meta:     appResourceMeta(definition.Description),
			}}}, nil
		})
	}
}

func appResourceMeta(description string) mcpsdk.Meta {
	return mcpsdk.Meta{
		"openai/widgetDescription":   description,
		"openai/widgetPrefersBorder": true,
		"openai/widgetCSP": map[string]any{
			"connect_domains":  []string{},
			"resource_domains": []string{},
		},
	}
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
:root{color-scheme:light dark;font:13px/1.45 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
*{box-sizing:border-box}body{margin:0;padding:12px;background:transparent;color:CanvasText}main{border:1px solid color-mix(in srgb,CanvasText 16%,transparent);border-radius:12px;padding:14px;background:color-mix(in srgb,Canvas 96%,CanvasText 4%)}
header{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}h1{font-size:14px;margin:0;font-weight:650}.muted{opacity:.65}.chip{display:inline-flex;align-items:center;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:999px;padding:2px 7px;font-size:11px}.summary{margin:8px 0 0;white-space:pre-wrap}
.progress{height:7px;margin:10px 0;border-radius:999px;overflow:hidden;background:color-mix(in srgb,CanvasText 10%,transparent)}.progress>span{display:block;height:100%;background:CanvasText;opacity:.65}.steps{display:grid;gap:6px;margin-top:10px}.step{display:grid;grid-template-columns:10px 1fr auto;gap:8px;align-items:start}.dot{width:8px;height:8px;margin-top:5px;border-radius:50%;border:1px solid currentColor;opacity:.55}.step[data-status="completed"] .dot{background:currentColor;opacity:.8}.step[data-status="in_progress"] .dot{box-shadow:0 0 0 2px color-mix(in srgb,CanvasText 18%,transparent);opacity:1}.step-title{min-width:0}.step-status{font-size:11px;opacity:.6}
.meta{display:flex;flex-wrap:wrap;gap:6px;margin:6px 0 10px}.stat{font-size:11px;padding:2px 6px;border-radius:6px;background:color-mix(in srgb,CanvasText 7%,transparent)}pre{margin:0;max-height:420px;overflow:auto;border-radius:8px;padding:10px;background:color-mix(in srgb,CanvasText 6%,transparent);font:11.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}.diff-line{display:block;min-height:1.45em}.diff-add{background:rgba(30,160,80,.12)}.diff-del{background:rgba(210,60,60,.12)}.diff-hunk{font-weight:650;opacity:.8}.kv{display:grid;grid-template-columns:minmax(90px,.35fr) 1fr;gap:6px 10px;margin:8px 0}.kv-key{opacity:.6}.kv-value{min-width:0;overflow-wrap:anywhere}.empty{padding:8px 0;opacity:.6}
</style>
</head>
<body>
<main>
<header><h1 id="heading">{{TITLE}}</h1><span class="chip" id="view-chip">{{VIEW}}</span></header>
<div id="content" class="empty">Waiting for tool output…</div>
</main>
<script>
(()=>{
  "use strict";
  const expectedView="{{VIEW}}";
  const root=document.getElementById("content");
  const heading=document.getElementById("heading");
  let lastSerialized="";

  const el=(tag,className,text)=>{const node=document.createElement(tag);if(className)node.className=className;if(text!==undefined)node.textContent=String(text);return node};
  const isObject=value=>value!==null&&typeof value==="object"&&!Array.isArray(value);
  const scalar=value=>value===null||["string","number","boolean"].includes(typeof value);

  function extract(payload){
    if(!isObject(payload))return null;
    const candidates=[payload.structuredContent,payload.toolOutput,payload.result&&payload.result.structuredContent,payload.params&&payload.params.structuredContent,payload.params&&payload.params.toolOutput,payload.params&&payload.params.result&&payload.params.result.structuredContent];
    for(const value of candidates){if(isObject(value))return value}
    if(payload.view===expectedView)return payload;
    return null;
  }

  function hostOutput(){
    try{return extract({toolOutput:window.openai&&window.openai.toolOutput})}catch(_){return null}
  }

  function setTitle(data,fallback){heading.textContent=(typeof data.title==="string"&&data.title.trim())?data.title:fallback}

  function renderTask(data){
    const task=isObject(data.task)?data.task:{};
    setTitle(data,typeof task.title==="string"?task.title:"Task progress");
    const fragment=document.createDocumentFragment();
    const status=task.status||task.phase||"unknown";
    fragment.append(el("span","chip",status));
    if(typeof task.summary==="string"&&task.summary){fragment.append(el("p","summary",task.summary))}
    const completed=Number(task.completed_step_count||0),total=Number(task.step_count||0);
    if(total>0){const p=el("div","progress");const bar=el("span");bar.style.width=Math.max(0,Math.min(100,completed/total*100))+"%";p.append(bar);fragment.append(p);fragment.append(el("div","muted",completed+" / "+total+" steps completed"))}
    let steps=Array.isArray(task.steps)?task.steps:[];
    if(!steps.length&&isObject(task.current_step))steps=[task.current_step];
    if(steps.length){const list=el("div","steps");for(const step of steps){if(!isObject(step))continue;const row=el("div","step");row.dataset.status=String(step.status||"");row.append(el("span","dot"));row.append(el("div","step-title",step.title||step.id||"Step"));row.append(el("span","step-status",step.status||""));list.append(row)}fragment.append(list)}
    root.replaceChildren(fragment);
  }

  function renderDiff(data){
    setTitle(data,data.path||"File diff");
    const fragment=document.createDocumentFragment();
    const meta=el("div","meta");
    if(data.path)meta.append(el("span","stat",data.path));
    if(Number.isFinite(Number(data.insertions)))meta.append(el("span","stat","+"+Number(data.insertions)));
    if(Number.isFinite(Number(data.deletions)))meta.append(el("span","stat","−"+Number(data.deletions)));
    if(meta.childNodes.length)fragment.append(meta);
    if(data.summary)fragment.append(el("p","summary",data.summary));
    const pre=el("pre");
    const lines=String(data.diff||"").split("\n");
    for(const line of lines){let cls="diff-line";if(line.startsWith("@@"))cls+=" diff-hunk";else if(line.startsWith("+")&&!line.startsWith("+++"))cls+=" diff-add";else if(line.startsWith("-")&&!line.startsWith("---"))cls+=" diff-del";pre.append(el("span",cls,line+"\n"))}
    fragment.append(pre);root.replaceChildren(fragment);
  }

  function renderACP(data){
    const state=isObject(data.state)?data.state:{};
    setTitle(data,"ACP status");
    const fragment=document.createDocumentFragment();
    const important=["action","status","session_id","run_id","stop_reason","count","message"];
    const grid=el("div","kv");let count=0;
    for(const key of important){if(!scalar(state[key])||state[key]===undefined||state[key]===null||state[key]==="")continue;grid.append(el("div","kv-key",key));grid.append(el("div","kv-value",state[key]));count++}
    if(count)fragment.append(grid);
    const json=JSON.stringify(state,null,2)||"{}";
    fragment.append(el("pre","",json.length>60000?json.slice(0,60000)+"\n… truncated in view":json));
    root.replaceChildren(fragment);
  }

  function render(data){
    if(!isObject(data)||data.view!==expectedView)return;
    const serialized=JSON.stringify(data);if(serialized===lastSerialized)return;lastSerialized=serialized;
    if(expectedView==="task_progress")renderTask(data);else if(expectedView==="file_diff")renderDiff(data);else renderACP(data);
  }

  window.addEventListener("message",event=>{const data=extract(event.data);if(data)render(data)});
  const timer=setInterval(()=>{const data=hostOutput();if(data)render(data)},250);
  setTimeout(()=>clearInterval(timer),10000);
  const initial=hostOutput();if(initial)render(initial);
})();
</script>
</body>
</html>`

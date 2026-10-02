import React, { Suspense, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { LuminaProvider, useLuminaTheme, LuminaButton, LuminaIconButton, LuminaTextField, LuminaCheckbox, LuminaSwitch, LuminaSlider, LuminaSegmented, LuminaCard, LuminaTopBar, LuminaMenu, LuminaDialog, LuminaToast, tokens } from '../src';
import './showcase.css';
const GlassScene = React.lazy(() => import('./GlassScene'));
function Showcase() {
  const { mode, setMode } = useLuminaTheme();
  const [category,setCategory] = useState<'components'|'material'>('components');
  const [selected,setSelected] = useState<'day'|'week'|'month'>('day');
  const [checked,setChecked] = useState(true), [switchOn,setSwitchOn] = useState(false), [slider,setSlider] = useState(62);
  const [dialog,setDialog] = useState(false), [toast,setToast] = useState<string|null>(null), [scene,setScene] = useState(false);
  const notify = (text:string) => setToast(text);
  return <>
    <LuminaTopBar title="Lumina Web" leading={<span className="brand-mark" aria-hidden="true">✦</span>} trailing={<LuminaSegmented label="外观模式" options={[{value:'system',label:'系统'},{value:'light',label:'浅色'},{value:'dark',label:'深色'}]} value={mode} onChange={setMode}/>} />
    <main className="showcase-main">
      <header className="showcase-hero"><p className="eyebrow">LUMINA · WEB / 01</p><h2>让界面如光，触感如水。</h2><p>首批 React 组件，共享 Flutter 设计变量。真实控件保持清晰易用，玻璃质感轻轻浮在内容之上。</p><div className="hero-meta"><span>12 类基础控件</span><span>浅色 / 深色 / 系统</span><span>键盘与触控</span></div></header>
      <LuminaSegmented label="展示类别" options={[{value:'components',label:'基础组件'},{value:'material',label:'材质实验'}]} value={category} onChange={setCategory}/>
      {category === 'components' ? <div className="showcase-grid">
        <LuminaCard title="按钮与反馈"><p>轻盈的表面、高对比文字和清晰的交互状态。</p><div className="control-row"><LuminaButton variant="primary" onClick={() => notify('主要操作已完成')}>主要按钮</LuminaButton><LuminaButton onClick={() => notify('次要操作已完成')}>次要按钮</LuminaButton><LuminaButton variant="quiet">文字按钮</LuminaButton><LuminaIconButton label="收藏" onClick={() => notify('已收藏')}>☆</LuminaIconButton></div><div className="control-row"><LuminaButton disabled>不可用</LuminaButton><LuminaButton loading>处理中</LuminaButton><LuminaButton variant="danger" onClick={() => setDialog(true)}>打开对话框</LuminaButton></div></LuminaCard>
        <LuminaCard title="输入与选择"><div className="field-stack"><LuminaTextField label="任务名称" placeholder="写下下一步" hint="支持键盘输入与表单提示"/><LuminaTextField label="校验示例" defaultValue="" error="请输入内容"/><div className="control-row"><LuminaCheckbox label="完成后提醒" checked={checked} onChange={event=>setChecked(event.target.checked)}/><LuminaSwitch label="自动同步" checked={switchOn} onChange={event=>setSwitchOn(event.target.checked)}/></div><LuminaSlider label="强度" value={slider} onChange={event=>setSlider(Number(event.target.value))}/></div></LuminaCard>
        <LuminaCard title="选择与菜单"><p>方向键可切换分段选项和菜单项。</p><LuminaSegmented label="日历视图" options={[{value:'day',label:'日'},{value:'week',label:'周'},{value:'month',label:'月'}]} value={selected} onChange={setSelected}/><div className="control-row"><LuminaMenu label="更多操作" items={[{label:'复制链接',onSelect:()=>notify('链接已复制')},{label:'分享',onSelect:()=>notify('已打开分享')},{label:'暂不可用',disabled:true,onSelect:()=>{}}]}/></div></LuminaCard>
        <LuminaCard title="共享设计变量"><p>颜色、间距、圆角和动效定义于版本化 JSON。此 Web 页面直接读取，Flutter 端读取同一份设计变量。</p><div className="swatches">{Object.entries(tokens.color.light).slice(0,7).map(([name,color])=><div key={name}><span style={{background:color}}/><small>{name}</small></div>)}</div><code>lumina.v1.json · {tokens.version}</code></LuminaCard>
      </div> : <div className="showcase-grid"><LuminaCard title="触感如水" water><p>在玻璃上移动鼠标，留下轻微水痕。点击或轻触，让涟漪从指尖散开。</p><p>文字保持安静，水波自然消退。</p><div className="control-row"><LuminaButton>轻触玻璃</LuminaButton><LuminaButton water={false}>静态玻璃</LuminaButton></div></LuminaCard><LuminaCard title="可关闭的 3D 材质实验"><p>Three.js 只用于此展示；应用控件始终使用可访问的二维 HTML。</p><LuminaSwitch label="启用 3D 演示" checked={scene} onChange={event=>setScene(event.target.checked)}/>{scene ? <Suspense fallback={<p>加载材质展示…</p>}><GlassScene/></Suspense> : <div className="scene-placeholder">✧</div>}</LuminaCard></div>}
      <footer className="showcase-footer">Lumina Web · 第一阶段组件展示</footer>
    </main>
    <LuminaDialog open={dialog} title="确认操作" onClose={()=>setDialog(false)} actions={<><LuminaButton variant="quiet" onClick={()=>setDialog(false)}>取消</LuminaButton><LuminaButton variant="primary" onClick={()=>{setDialog(false);notify('已确认');}}>确认</LuminaButton></>}>对话框支持 Escape、焦点约束及背景遮挡。</LuminaDialog>
    {toast ? <LuminaToast message={toast} onDismiss={()=>setToast(null)}/> : null}
  </>;
}
createRoot(document.getElementById('root')!).render(<LuminaProvider><Showcase/></LuminaProvider>);

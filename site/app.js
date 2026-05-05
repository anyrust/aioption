// AI Option dApp — client-side JS. No inline scripts in HTML = no </ parsing issues.
const F="0x64EB6C9889d751F2578C2908bA50aff48c0843E5";
let signer,account;

async function getSigner(){
  if(!window.ethereum)throw new Error("Install MetaMask");
  if(!signer){
    const p=new ethers.BrowserProvider(window.ethereum);
    await p.send("eth_requestAccounts");
    signer=await p.getSigner();
    account=await signer.getAddress();
    try{await p.send("wallet_switchEthereumChain",[{chainId:"0xa4b1"}])}catch(e){
      if(e.code===4902)await window.ethereum.request({method:"wallet_addEthereumChain",params:[{chainId:"0xa4b1",chainName:"Arbitrum One",rpcUrls:["https://arb1.arbitrum.io/rpc"],nativeCurrency:{name:"ETH",symbol:"ETH",decimals:18},blockExplorerUrls:["https://arbiscan.io"]}]});
    }
  }
  return signer;
}

document.querySelectorAll(".tab").forEach(t=>t.onclick=()=>{
  document.querySelectorAll(".tab,.tab-content").forEach(e=>e.classList.remove("active"));
  t.classList.add("active");document.getElementById(t.dataset.tab).classList.add("active");
});

async function createOption(){
  try{
    const s=await getSigner();
    const q=document.getElementById("cq").value;
    const opts=document.getElementById("co").value.split(",").map(o=>o.trim());
    const mr=parseInt(document.getElementById("cmr").value);
    const td=parseInt(document.getElementById("ctd").value);
    const rw=parseInt(document.getElementById("crw").value);
    const now=Math.floor(Date.now()/1000);
    const f=new ethers.Contract(F,["function createOption((string,string,uint256,bytes32,uint256,uint256,uint256,uint256,string[]))"],s);
    const fp="0xdeadbeef01000000000000000000000000000000000000000000000000000000";
    const tx=await f.createOption([q,"aijudge",1,fp,now,now+td*60,now+(td+rw)*60,mr,opts]);
    const e=document.getElementById("createTx");
    e.style.display="block";e.textContent="TX: "+tx.hash;
    await tx.wait();e.textContent="Created! Reloading...";location.reload();
  }catch(e){
    document.getElementById("createTx").style.display="block";
    document.getElementById("createTx").textContent="Error: "+e.message;
  }
}

async function showOption(addr){
  const r=await fetch("/api/options.json");const d=await r.json();
  const o=d.options.find(x=>x.address===addr);if(!o)return;
  const id="opt"+addr.slice(2,10);
  const detail=document.getElementById("optionDetail");detail.innerHTML="";
  const card=el("div","card",id);
  card.appendChild(el("h2","",null,o.question));
  const pre=el("pre","data",null,"Addr: "+o.address+"  Status: "+o.status+"  Winner: "+o.winner+"  Settled: "+o.settled+"  Resolutions: "+o.resolutionCount+"/"+o.minResolutions+"  Round: "+o.reRound);
  card.appendChild(pre);
  const obDiv=el("div","",id);obDiv.innerHTML="<em>Loading OrderBook...</em>";
  card.appendChild(obDiv);
  card.appendChild(document.createElement("br"));
  [{label:"Deposit ETH",cls:"btn green",fn:()=>deposit(addr)},{label:"Claim",cls:"btn",fn:()=>claim(addr)},{label:"Force Resolve",cls:"btn red",fn:()=>forceResolve(addr)}].forEach(b=>{
    const btn=el("button",b.cls,null,b.label);btn.onclick=b.fn;card.appendChild(btn);card.appendChild(document.createTextNode(" "));
  });
  const txPre=el("pre","tx","tx-"+id);card.appendChild(txPre);
  detail.appendChild(card);
  loadOrderBookAuto("ob-content-"+id,addr);
}

function el(tag,cls,id,txt){
  const e=document.createElement(tag);
  if(cls)e.className=cls;if(id)e.id=id;if(txt)e.textContent=txt;
  return e;
}

async function loadOrderBookAuto(containerId,optAddr){
  const container=document.getElementById(containerId);
  try{
    const s=await getSigner();
    const factory=new ethers.Contract(F,["function getOrderBook(address) view returns (address)"],s);
    const obAddr=await factory.getOrderBook(optAddr);
    if(!obAddr||obAddr==="0x"+"0".padStart(40,"0")){container.textContent="No OrderBook";return}
    container.textContent="";
    container.appendChild(el("h3","",null,"OrderBook: "+obAddr.slice(0,14)+"..."));
    const ob=new ethers.Contract(obAddr,["function getBook(uint256) view returns (uint256[],uint256[],uint256[],uint256[])","function placeBuy(uint256,uint256,uint256)","function deposit() payable","function balances(address) view returns (uint256)"],s);
    const[bp,ba,ap,aa]=await ob.getBook(0);const[bp1,ba1,ap1,aa1]=await ob.getBook(1);
    const bal=await ob.balances(await s.getAddress());
    container.appendChild(el("p","",null,"Balance: "+Number(ethers.formatEther(bal)).toFixed(6)+" ETH"));
    const tbl=document.createElement("table");const thr=tbl.createTHead().insertRow();
    ["Side","Price","Shares"].forEach(h=>{const th=document.createElement("th");th.textContent=h;thr.appendChild(th)});
    const tb=tbl.createTBody();
    [[bp,ba,"YES Bid"],[ap,aa,"YES Ask"],[bp1,ba1,"NO Bid"],[ap1,aa1,"NO Ask"]].forEach(([prices,amounts,label])=>{
      for(let i=0;i<prices.length;i++){const tr=tb.insertRow();[label,Number(ethers.formatEther(prices[i])).toFixed(4),Number(ethers.formatEther(amounts[i])).toFixed(4)].forEach(v=>{const td=tr.insertCell();td.textContent=v})}
    });
    container.appendChild(tbl);
    const div=document.createElement("div");div.style.marginTop="8px";
    const depBtn=el("button","btn",null,"Deposit 0.001 ETH");depBtn.onclick=()=>obDeposit(obAddr);
    const priceIn=document.createElement("input");priceIn.id="ob-price-"+containerId;priceIn.value="0.5";priceIn.style="width:80px;padding:4px";
    const amtIn=document.createElement("input");amtIn.id="ob-amt-"+containerId;amtIn.value="0.01";amtIn.style="width:80px;padding:4px";
    const sel=document.createElement("select");sel.id="ob-side-"+containerId;
    [{v:0,t:"Buy YES"},{v:1,t:"Buy NO"}].forEach(o=>{const opt=document.createElement("option");opt.value=o.v;opt.textContent=o.t;sel.appendChild(opt)});
    const buyBtn=el("button","btn green",null,"Place Buy");buyBtn.onclick=()=>obBuy(obAddr,containerId);
    div.append(depBtn,priceIn,amtIn,sel,buyBtn);
    container.appendChild(div);
  }catch(e){container.textContent="Connect MetaMask: "+e.message}
}

async function obDeposit(obAddr){try{const s=await getSigner();const c=new ethers.Contract(obAddr,["function deposit() payable"],s);const tx=await c.deposit({value:ethers.parseEther("0.001")});await tx.wait();alert("OK: "+tx.hash);location.reload()}catch(e){alert(e.message)}}
async function obBuy(obAddr,cid){try{const s=await getSigner();const px=ethers.parseEther(document.getElementById("ob-price-"+cid).value);const amt=ethers.parseEther(document.getElementById("ob-amt-"+cid).value);const side=parseInt(document.getElementById("ob-side-"+cid).value);const c=new ethers.Contract(obAddr,["function placeBuy(uint256,uint256,uint256)"],s);const tx=await c.placeBuy(side,px,amt);await tx.wait();alert("OK: "+tx.hash);location.reload()}catch(e){alert(e.message)}}

async function deposit(addr){try{const s=await getSigner();const tx=await s.sendTransaction({to:addr,value:ethers.parseEther("0.001"),data:"0xd0e30db0"});alert("TX: "+tx.hash);await tx.wait()}catch(e){alert(e.message)}}
async function claim(addr){try{const s=await getSigner();const f=new ethers.Contract(addr,["function claimReward()"],s);const tx=await f.claimReward();alert("TX: "+tx.hash);await tx.wait()}catch(e){alert(e.message)}}
async function forceResolve(addr){try{const s=await getSigner();const f=new ethers.Contract(addr,["function forceResolve()"],s);const tx=await f.forceResolve();alert("TX: "+tx.hash);await tx.wait()}catch(e){alert(e.message)}}

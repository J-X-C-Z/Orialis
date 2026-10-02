import { Canvas, useFrame } from '@react-three/fiber';
import { useRef } from 'react';
import * as THREE from 'three';
function Lens() {
  const mesh = useRef<THREE.Mesh>(null);
  useFrame((state, delta) => { if (mesh.current) { mesh.current.rotation.y += delta * .18; mesh.current.rotation.x = Math.sin(state.clock.elapsedTime * .3) * .12; } });
  return <mesh ref={mesh}><torusGeometry args={[1.1, .28, 24, 96]}/><meshPhysicalMaterial color="#9acbff" metalness={.12} roughness={.08} transmission={.72} thickness={1.1} ior={1.42} clearcoat={1} clearcoatRoughness={.04}/></mesh>;
}
export default function GlassScene() {
  return <div className="glass-scene" role="img" aria-label="旋转的玻璃材质圆环实验"><Canvas dpr={[1,1.5]} frameloop="always" camera={{ position:[0,0,4], fov:42 }}><ambientLight intensity={1.5}/><directionalLight position={[2,3,4]} intensity={4}/><pointLight position={[-2,-1,2]} intensity={16} color="#5ea4ff"/><Lens/></Canvas></div>;
}

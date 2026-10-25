#[compute]
#version 450
// GPU port of limb_solver.gd and the existing 22-degree contact correction.
// One invocation owns one leg. No atomics, cross-leg writes, or history delay.
layout(local_size_x = 64) in;
layout(set=0,binding=0,std430) readonly buffer Inputs { float input_data[]; };
layout(set=0,binding=1,std430) readonly buffer Rigs { float rig_data[]; };
layout(set=0,binding=2,std430) writeonly buffer Outputs { float output_data[]; };
layout(push_constant,std430) uniform Count { uint count; } pc;
const int STRIDE=136, CONFIG=100, OUT_STRIDE=40, MAX_CHAIN=8;
const float PI=3.141592653589793, TAU=6.283185307179586;
const vec4 IDENTITY_Q=vec4(0,0,0,1);
struct Pose { mat3 b; vec3 p; };
Pose local_pose[MAX_CHAIN], source_pose[MAX_CHAIN], globals[MAX_CHAIN];
Pose base;
int mutable_bones[4];
int size, config_start, in_start, out_start;
vec3 target, sole;
mat3 sole_basis;
float budget;
float ambiguous=0;

vec3 inv3(int i) { return vec3(input_data[i],input_data[i+1],input_data[i+2]); }
mat3 in_basis(int i) { return mat3(inv3(i),inv3(i+3),inv3(i+6)); }
vec3 rv3(int i) { return vec3(rig_data[i],rig_data[i+1],rig_data[i+2]); }
mat3 r_basis(int i) { return mat3(rv3(i),rv3(i+3),rv3(i+6)); }
Pose read_pose(int i) { return Pose(in_basis(i),inv3(i+9)); }
mat3 ortho(mat3 m) {
    vec3 x=normalize(m[0]);
    vec3 y=normalize(m[1]-x*dot(x,m[1]));
    vec3 z=normalize(m[2]-x*dot(x,m[2])-y*dot(y,m[2]));
    return mat3(x,y,z);
}
vec3 scale_of(mat3 m) { return sign(determinant(m))*vec3(length(m[0]),length(m[1]),length(m[2])); }
vec4 quat(mat3 raw) {
    mat3 m=ortho(raw);
    if(determinant(m)<0) m=-m;
    float trace=m[0][0]+m[1][1]+m[2][2];
    vec4 q;
    if(trace>0) {
        float s=sqrt(trace+1.0); q.w=.5*s; s=.5/s;
        q.x=(m[1][2]-m[2][1])*s;
        q.y=(m[2][0]-m[0][2])*s;
        q.z=(m[0][1]-m[1][0])*s;
    } else {
        int i=m[0][0]<m[1][1] ? (m[1][1]<m[2][2]?2:1) : (m[0][0]<m[2][2]?2:0);
        int j=(i+1)%3,k=(i+2)%3;
        float s=sqrt(m[i][i]-m[j][j]-m[k][k]+1.0); q[i]=.5*s; s=.5/s;
        q.w=(m[j][k]-m[k][j])*s;
        q[j]=(m[i][j]+m[j][i])*s;
        q[k]=(m[i][k]+m[k][i])*s;
    }
    return q;
}
vec4 qmul(vec4 a,vec4 b) { return vec4(a.w*b.xyz+b.w*a.xyz+cross(a.xyz,b.xyz),a.w*b.w-dot(a.xyz,b.xyz)); }
vec4 qinv(vec4 q) { return vec4(-q.xyz,q.w); }
mat3 basis(vec4 q) {
    // Godot Basis(Quaternion) divides by length squared.
    float s=2.0/dot(q,q); vec3 v=q.xyz;
    float xx=v.x*v.x*s,yy=v.y*v.y*s,zz=v.z*v.z*s;
    float xy=v.x*v.y*s,xz=v.x*v.z*s,yz=v.y*v.z*s;
    float wx=q.w*v.x*s,wy=q.w*v.y*s,wz=q.w*v.z*s;
    return mat3(vec3(1-yy-zz,xy+wz,xz-wy),vec3(xy-wz,1-xx-zz,yz+wx),vec3(xz+wy,yz-wx,1-xx-yy));
}
float qangle(vec4 a,vec4 b) { float d=dot(a,b); return acos(clamp(d*d*2.0-1.0,-1.0,1.0)); }
float angle(vec4 q) { return 2.0*acos(clamp(q.w,-1.0,1.0)); }
vec4 qslerp(vec4 a,vec4 b,float t) {
    float c=dot(a,b); if(c<0) { c=-c; b=-b; }
    if(1.0-c<=.00001) return mix(a,b,t);
    float omega=acos(clamp(c,-1.0,1.0));
    return (sin((1.0-t)*omega)*a+sin(t*omega)*b)/sin(omega);
}
vec4 alignment(vec3 a,vec3 b) {
    if(dot(a,a)<1e-12 || dot(b,b)<1e-12) return IDENTITY_Q;
    a=normalize(a); b=normalize(b); float d=dot(a,b);
    // Match Quaternion(Vector3, Vector3), including its antiparallel branch.
    if(abs(d)>.99999975) {
        if(d>=0) return IDENTITY_Q;
        vec3 axis=abs(a.x)<=abs(a.y) && abs(a.x)<=abs(a.z) ? vec3(1,0,0) : vec3(0,1,0);
        return vec4(normalize(cross(a,axis)),0);
    }
    float s=sqrt((1.0+d)*2.0);
    return normalize(vec4(cross(a,b)/s,s*.5));
}
void fk() {
    Pose parent=base;
    for(int i=0;i<size;i++) {
        globals[i]=Pose(parent.b*local_pose[i].b,parent.b*local_pose[i].p+parent.p);
        parent=globals[i];
    }
}
void rotate_world(int bone,vec4 rotation) {
    mat3 parent=bone==0?base.b:globals[bone-1].b;
    vec4 desired=qmul(normalize(rotation),quat(globals[bone].b));
    vec4 relative=qmul(qinv(quat(parent)),desired);
    local_pose[bone].b=basis(normalize(relative))*mat3(vec3(scale_of(local_pose[bone].b).x,0,0),vec3(0,scale_of(local_pose[bone].b).y,0),vec3(0,0,scale_of(local_pose[bone].b).z));
}
mat3 constrain(int joint,mat3 b) {
    int at=config_start+4+joint*24;
    mat3 parent=r_basis(at),rest=r_basis(at+9);
    vec3 axis=rv3(at+18);
    float lower=rig_data[at+21],upper=rig_data[at+22],swing_limit=rig_data[at+23];
    vec4 rotation=quat(parent*ortho(b)*inverse(rest)*inverse(parent));
    if(rotation.w<0) rotation=-rotation;
    vec4 twist=vec4(axis*dot(rotation.xyz,axis),rotation.w);
    twist=dot(twist,twist)<1e-10?IDENTITY_Q:normalize(twist);
    float bend=mod(2.0*atan(dot(twist.xyz,axis),twist.w)+PI,TAU)-PI;
    vec4 swing=normalize(qmul(rotation,qinv(twist)));
    float swing_angle=angle(swing);
    if(bend>=lower && bend<=upper && swing_angle<=swing_limit) return b;
    bend=clamp(bend,lower,upper);
    if(swing_angle>swing_limit) swing=qslerp(IDENTITY_Q,swing,swing_limit/swing_angle);
    vec4 hinge=vec4(axis*sin(bend*.5),cos(bend*.5));
    mat3 result=inverse(parent)*basis(qmul(swing,hinge))*parent*rest;
    vec3 scale=scale_of(b);
    return mat3(result[0]*scale.x,result[1]*scale.y,result[2]*scale.z);
}
void interpolate_source(int bone,float t) {
    // Transform3D.interpolate_with: scale and rotation decomposed separately.
    vec3 scale=mix(scale_of(source_pose[bone].b),scale_of(local_pose[bone].b),t);
    mat3 b=basis(normalize(qslerp(quat(source_pose[bone].b),quat(local_pose[bone].b),t)));
    local_pose[bone].b=mat3(b[0]*scale.x,b[1]*scale.y,b[2]*scale.z);
    local_pose[bone].p=mix(source_pose[bone].p,local_pose[bone].p,t);
}
void bound_rotation(int joint) {
    int bone=mutable_bones[joint];
    local_pose[bone].b=constrain(joint,local_pose[bone].b);
    float a=qangle(quat(source_pose[bone].b),quat(local_pose[bone].b));
    if(a>budget) interpolate_source(bone,budget/a);
    local_pose[bone].b=constrain(joint,local_pose[bone].b);
}
void analytic(vec3 pole,float epsilon,float flex) {
    int middle=mutable_bones[2],leaf=mutable_bones[3];
    fk();
    vec3 r=globals[0].p,m=globals[middle].p,e=globals[leaf].p;
    float a=length(m-r),b=length(e-m);
    vec3 leaf_target=target-sole_basis*(sole*scale_of(globals[leaf].b));
    vec3 direction=leaf_target-r;
    float distance=length(direction);
    if(a<epsilon || b<epsilon || distance<epsilon) return;
    direction/=distance;
    float min_reach=sqrt(max(0.0,a*a+b*b+2.0*a*b*cos(flex)));
    float reach=clamp(distance,max(min_reach,abs(a-b)+epsilon),a+b-epsilon);
    vec3 bend=pole-direction*dot(pole,direction);
    if(dot(bend,bend)<1e-10) {
        bend=cross(direction,vec3(1,0,0));
        if(dot(bend,bend)<1e-10) bend=cross(direction,vec3(0,1,0));
    }
    bend=normalize(bend);
    float along=(a*a-b*b+reach*reach)/(2.0*reach);
    vec3 wanted=r+direction*along+bend*sqrt(max(0.0,a*a-along*along));
    rotate_world(0,alignment(m-r,wanted-r)); fk();
    rotate_world(middle,alignment(globals[leaf].p-globals[middle].p,r+direction*reach-globals[middle].p)); fk();
    rotate_world(leaf,qmul(quat(sole_basis),qinv(quat(globals[leaf].b))));
}
void refine() {
    int leaf=mutable_bones[3];
    for(int j=0;j<4;j++) { int b=mutable_bones[j]; local_pose[b].b=constrain(j,local_pose[b].b); }
    fk();
    float best_error=length(globals[leaf].b*sole+globals[leaf].p-target);
    if(best_error<.006) return;
    Pose best[4];
    for(int j=0;j<4;j++) best[j]=local_pose[mutable_bones[j]];
    for(int iteration=0;iteration<6;iteration++) {
        for(int j=2;j>=0;j--) {
            int bone=mutable_bones[j]; fk();
            vec3 pivot=globals[bone].p,s=globals[leaf].b*sole+globals[leaf].p;
            rotate_world(bone,qslerp(IDENTITY_Q,alignment(s-pivot,target-pivot),.65));
            bound_rotation(j);
        }
        fk(); rotate_world(leaf,qmul(quat(sole_basis),qinv(quat(globals[leaf].b)))); bound_rotation(3);
        fk(); float error=length(globals[leaf].b*sole+globals[leaf].p-target);
        // Almost tied residuals can select different refinement iterations after
        // float32 rounding. Preserve the original answer through a CPU retry
        // only when those tied candidates have meaningfully different soles.
        if(error < best_error-.00005) ambiguous=0;
        else if(abs(error-best_error)<.00005) {
            Pose candidate[4];
            for(int j=0;j<4;j++) { candidate[j]=local_pose[mutable_bones[j]]; local_pose[mutable_bones[j]]=best[j]; }
            vec3 candidate_sole=globals[leaf].b*sole+globals[leaf].p;
            fk();
            if(length(candidate_sole-(globals[leaf].b*sole+globals[leaf].p))>.00025) ambiguous=1;
            for(int j=0;j<4;j++) local_pose[mutable_bones[j]]=candidate[j];
        }
        if(error<best_error) {
            best_error=error;
            for(int j=0;j<4;j++) best[j]=local_pose[mutable_bones[j]];
        }
        if(best_error<.002) break;
    }
    for(int j=0;j<4;j++) local_pose[mutable_bones[j]]=best[j];
}
void main() {
    uint job=gl_GlobalInvocationID.x; if(job>=pc.count) return;
    in_start=int(job)*STRIDE; out_start=int(job)*OUT_STRIDE;
    config_start=int(input_data[in_start])*CONFIG;
    size=int(rig_data[config_start]);
    mutable_bones[0]=0;
    for(int j=1;j<4;j++) mutable_bones[j]=int(rig_data[config_start+j]);
    base=read_pose(in_start+4);
    for(int i=0;i<size;i++) { source_pose[i]=read_pose(in_start+16+i*12); local_pose[i]=source_pose[i]; }
    target=inv3(in_start+112); budget=input_data[in_start+115];
    sole=inv3(in_start+116); sole_basis=in_basis(in_start+120);
    float maximum=0.0;
    if(input_data[in_start+1]>.5) {
        analytic(inv3(in_start+132),input_data[in_start+2],input_data[in_start+3]);
        for(int j=0;j<4;j++) {
            if(j==1) continue; int bone=mutable_bones[j];
            maximum=max(maximum,qangle(quat(source_pose[bone].b),quat(local_pose[bone].b)));
        }
        if(maximum>budget) {
            for(int j=0;j<4;j++) if(j!=1) interpolate_source(mutable_bones[j],budget/maximum);
        }
        refine();
    }
    float correction=min(maximum,budget);
    for(int j=0;j<4;j++) {
        int bone=mutable_bones[j]; mat3 b=local_pose[bone].b;
        correction=max(correction,qangle(quat(source_pose[bone].b),quat(b)));
        for(int col=0;col<3;col++) for(int row=0;row<3;row++) output_data[out_start+j*9+col*3+row]=b[col][row];
    }
    output_data[out_start+36]=maximum>budget?1.0:0.0;
    output_data[out_start+37]=correction;
    fk(); int leaf=mutable_bones[3];
    output_data[out_start+38]=length(globals[leaf].b*sole+globals[leaf].p-target);
    output_data[out_start+39]=ambiguous;
}

import math
PI = math.pi; SOLAR = 4*PI*PI; DAYS = 365.24
class Body:
    __slots__ = ('x','y','z','vx','vy','vz','mass')
    def __init__(s, x, y, z, vx, vy, vz, mass):
        s.x, s.y, s.z, s.vx, s.vy, s.vz, s.mass = x, y, z, vx, vy, vz, mass
bodies = [
    Body(0,0,0,0,0,0,SOLAR),
    Body(4.84143144246472090e+00,-1.16032004402742839e+00,-1.03622044471123109e-01,1.66007664274403694e-03*DAYS,7.69901118419740425e-03*DAYS,-6.90460016972063023e-05*DAYS,9.54791938424326609e-04*SOLAR),
    Body(8.34336671824457987e+00,4.12479856412430479e+00,-4.03523417114321381e-01,-2.76742510726862411e-03*DAYS,4.99852801234917238e-03*DAYS,2.30417297573763929e-05*DAYS,2.85885980666130812e-04*SOLAR),
    Body(1.28943695621391310e+01,-1.51111514016986312e+01,-2.23307578892655734e-01,2.96460137564761618e-03*DAYS,2.37847173959480950e-03*DAYS,-2.96589568540237556e-05*DAYS,4.36624404335156298e-05*SOLAR),
    Body(1.53796971148509165e+01,-2.59193146099879641e+01,1.79258772950371181e-01,2.68067772490389322e-03*DAYS,1.62824170038242295e-03*DAYS,-9.51592254519715870e-05*DAYS,5.15138902046611451e-05*SOLAR),
]
def advance(bodies, dt):
    n = len(bodies)
    for i in range(n):
        a = bodies[i]
        for j in range(i+1, n):
            b = bodies[j]
            dx = a.x-b.x; dy = a.y-b.y; dz = a.z-b.z
            d2 = dx*dx+dy*dy+dz*dz
            mag = dt/(d2*math.sqrt(d2))
            a.vx -= dx*b.mass*mag; a.vy -= dy*b.mass*mag; a.vz -= dz*b.mass*mag
            b.vx += dx*a.mass*mag; b.vy += dy*a.mass*mag; b.vz += dz*a.mass*mag
    for b in bodies:
        b.x += dt*b.vx; b.y += dt*b.vy; b.z += dt*b.vz
def energy(bodies):
    e = 0.0; n = len(bodies)
    for i in range(n):
        a = bodies[i]
        e += 0.5*a.mass*(a.vx*a.vx+a.vy*a.vy+a.vz*a.vz)
        for j in range(i+1, n):
            b = bodies[j]
            dx = a.x-b.x; dy = a.y-b.y; dz = a.z-b.z
            e -= a.mass*b.mass/math.sqrt(dx*dx+dy*dy+dz*dz)
    return e
px = sum(b.vx*b.mass for b in bodies); py = sum(b.vy*b.mass for b in bodies); pz = sum(b.vz*b.mass for b in bodies)
bodies[0].vx = -px/SOLAR; bodies[0].vy = -py/SOLAR; bodies[0].vz = -pz/SOLAR
print("%.9f" % energy(bodies))
for _ in range(500000): advance(bodies, 0.01)
print("%.9f" % energy(bodies))

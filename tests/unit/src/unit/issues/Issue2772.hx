package unit.issues;

class Issue2772 extends Test
{
#if jvm
	public function test()
	{
		var f = false;
		jvm.Jvm.lock(Issue2772, f = true);
		t(f);
		jvm.Jvm.lock(this, f = false);
		this.f(f);
	}
#end
}

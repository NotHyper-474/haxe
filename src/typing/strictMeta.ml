open Globals
open Ast
open Type
open Common
open Typecore

let get_native_repr md pos =
	let path, meta = match md with
		| TClassDecl cl -> cl.cl_path, cl.cl_meta
		| TEnumDecl e -> e.e_path, e.e_meta
		| TTypeDecl t -> t.t_path, t.t_meta
		| TAbstractDecl a -> a.a_path, a.a_meta
	in
	let rec loop acc = function
		| (Meta.Native,[EConst(String(name,_)),_],_) :: meta ->
			loop (Ast.parse_path name) meta
		| _ :: meta ->
			loop acc meta
		| [] ->
			acc
	in
	let pack, name = loop path meta in
	match pack with
		| [] ->
			(EConst(Ident(name)), pos)
		| hd :: tl ->
			let rec loop pack expr = match pack with
				| hd :: tl ->
					loop tl (efield(expr,hd),pos)
				| [] ->
					(efield(expr,name),pos)
			in
			loop tl (EConst(Ident(hd)),pos)

let rec process_meta_argument ?(toplevel=true) ctx expr = match expr.eexpr with
	| TField(e,f) ->
		(efield(process_meta_argument ~toplevel:false ctx e,field_name f),expr.epos)
	| TConst(TInt i) ->
		(EConst(Int (Int32.to_string i, None)), expr.epos)
	| TConst(TFloat f) ->
		(EConst(Float (f, None)), expr.epos)
	| TConst(TString s) ->
		(EConst(String(s,SDoubleQuotes)), expr.epos)
	| TConst TNull ->
		(EConst(Ident "null"), expr.epos)
	| TConst(TBool b) ->
		(EConst(Ident (string_of_bool b)), expr.epos)
	| TCast(e,_) | TMeta(_,e) | TParenthesis(e) ->
		process_meta_argument ~toplevel ctx e
	| TTypeExpr md when toplevel ->
		let p = expr.epos in
		(efield(get_native_repr md expr.epos, "class"), p)
	| TTypeExpr md ->
		get_native_repr md expr.epos
	| TArrayDecl el ->
		let el = List.map (process_meta_argument ctx) el in
		(EArrayDecl el,expr.epos)
	| _ ->
		display_error ctx.com "This expression is too complex to be a strict metadata argument" expr.epos;
		(EConst(Ident "null"), expr.epos)

let rec kind_of_type_against ctx t_want e_have =
	match follow t_want with
	| TInst({cl_path = (["java";"lang"],"Class")},[t1]) ->
		let e = type_expr ctx e_have (WithType.with_type t_want) in
		begin match follow e.etype with
			| TAbstract({a_path = ([],"Class")},[t2]) ->
				unify ctx t2 t1 e.epos
			| TAnon an ->
				begin match !(an.a_status) with
					| ClassStatics c ->
						unify ctx (TInst(c,extract_param_types c.cl_params)) t1 e.epos
					| AbstractStatics a ->
						unify ctx (TAbstract(a,extract_param_types a.a_params)) t1 e.epos
					| _ ->
						unify ctx e.etype t_want e.epos
				end
			| _ ->
				unify ctx e.etype t_want e.epos
		end;
		e
	| TInst({cl_path = (["jvm"],"NativeArray")},[t1]) ->
		begin match fst e_have with
			| EArrayDecl el ->
				let el = List.map (kind_of_type_against ctx t1) el in
				mk (TArrayDecl el) t1 (snd e_have)
			| _ ->
				let e = type_expr ctx e_have (WithType.with_type t_want) in
				unify ctx e.etype t_want e.epos;
				e
		end
	| t1 ->
		let e = type_expr ctx e_have (WithType.with_type t1) in
		unify ctx e.etype t1 e.epos;
		e

let handle_fields ctx fields_to_check with_type_expr =
	List.map (fun ((name,_,_),expr) ->
		let pos = snd expr in
		let field = (efield(with_type_expr,name), pos) in
		let fieldexpr = (EConst(Ident name),pos) in
		let left_side = (ECall(field,[]),pos) in
		let left = type_expr ctx left_side NoValue in
		let right = kind_of_type_against ctx left.etype expr in
		(EBinop(Ast.OpAssign,fieldexpr,process_meta_argument ctx right), pos)
	) fields_to_check

let make_meta ctx texpr extra =
	match texpr.eexpr with
		| TNew(c,_,el) ->
			ECall(get_native_repr (TClassDecl c) texpr.epos, (List.map (process_meta_argument ctx) el) @ extra), texpr.epos
		| TTypeExpr(md) ->
			ECall(get_native_repr md texpr.epos, extra), texpr.epos
		| _ ->
			display_error ctx.com "Unexpected expression" texpr.epos; die "" __LOC__

let field_to_type_path com e =
	let rec loop e pack name = match e with
		| EField(e,f,_),p when Char.lowercase_ascii (String.get f 0) <> String.get f 0 -> (match name with
			| [] | _ :: [] ->
				loop e pack (f :: name)
			| _ -> (* too many name paths *)
				display_error com ("Unexpected " ^ f) p;
				raise Exit)
		| EField(e,f,_),_ ->
			loop e (f :: pack) name
		| EConst(Ident f),_ ->
			let pack, name, sub = match name with
				| [] ->
					let fchar = String.get f 0 in
					if Char.uppercase_ascii fchar = fchar then
						pack, f, None
					else begin
						display_error com "A class name must start with an uppercase letter" (snd e);
						raise Exit
					end
				| [name] ->
					f :: pack, name, None
				| [name; sub] ->
					f :: pack, name, Some sub
				| _ ->
					die "" __LOC__
			in
			{ tpackage=pack; tname=name; tparams=[]; tsub=sub }
		| _,pos ->
			display_error com "Unexpected expression when building strict meta" pos;
			raise Exit
	in
	loop e [] []

let get_strict_meta ctx meta params pos =
	let changed_expr, fields_to_check, ctype = match params with
		| [ECall(ef, el),p] ->
			let tpath = field_to_type_path ctx.com ef in
			let fields = match el with
			| [EObjectDecl(fields),_] ->
				fields
			| [] ->
				[]
			| (_,p) :: _ ->
				display_error ctx.com "Object declaration expected" p;
				[]
			in
			ef, fields, CTPath (make_ptp tpath (snd ef))
		| [EConst(Ident i),p as expr] ->
			let tpath = { tpackage=[]; tname=i; tparams=[]; tsub=None } in
			let ptp = make_ptp tpath p in
			expr, [], CTPath ptp
		| [ (EField(_),p as field) ] ->
			let tpath = field_to_type_path ctx.com field in
			let ptp = make_ptp tpath p in
			field, [], CTPath ptp
		| _ ->
			display_error ctx.com "A @:strict metadata must contain exactly one parameter. Please check the documentation for more information" pos;
			raise Exit
	in
	let t = Typeload.load_complex_type ctx false LoadNormal (ctype,pos) in
	flush_pass ctx.g PBuildClass "get_strict_meta";
	let texpr = type_expr ctx changed_expr NoValue in
	let with_type_expr = (ECheckType( (EConst (Ident "null"), pos), (ctype,null_pos) ), pos) in
	let extra = handle_fields ctx fields_to_check with_type_expr in
	let args = [make_meta ctx texpr extra] in
	let args = match t with
		| TInst(c,_) ->
			let v = get_meta_string c.cl_meta Meta.Annotation in
			begin match v with
			| None ->
				(* We explicitly set this to the default retention policy CLASS. This allows us to treat
				   @:strict as default CLASS and @:meta as default RUNTIME. *)
				args @ [EConst (String("CLASS",SDoubleQuotes)),pos]
			| Some v ->
				args @ [EConst (String(v,SDoubleQuotes)),pos]
			end;
		| _ ->
			args
	in
	meta, args, pos

let check_strict_meta ctx metas =
	let pf = ctx.com.platform in
	match pf with
		| Jvm ->
			let ret = ref [] in
			List.iter (function
				| Meta.Strict,params,pos -> (try
					ret := get_strict_meta ctx Meta.Meta params pos :: !ret
				with | Exit -> ())
				| _ -> ()
			) metas;
			!ret
		| _ -> []

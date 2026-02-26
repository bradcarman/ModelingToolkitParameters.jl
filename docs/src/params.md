# How to use `params` helper function
The `params` function provides a quick way to generate the struct code for a model function.  

```@example params
using ModelingToolkitParameters
using ActiveSuspensionModel
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D

@component function Motor(; name, k = 0.1, r = 0.01, l = 1e-3)
  pars = @parameters begin
    k = k
    r = r
    l = l
  end
  vars = @variables begin
    v(t)
    dphi(t) = 0
    i(t) = 0
    di(t)
  end
  eqs = Equation[
    D(i) ~ di
    v ~ i * r + l * di + dphi * k
    D(dphi) ~ k * i
    v ~ sin(t)
  ]

  return System(eqs, t, vars, pars; name)
end

code = ModelingToolkitParameters.params(Motor) #code also placed in clipboard
```

Now this code can be pasted alongside the component definition, making it easy to implement `ModelingToolkitParameters` for your models.

